package stream

import (
	"net"
	"sync"
	"time"
)

// transmitter 是可靠发送端:窗口内的帧交给传输层,超时重传,
// 累积确认到达后裁剪;Close 后先送完全部数据确认,再发 Close 帧。
type transmitter struct {
	sess *Session
	peer net.IP
	id   uint32

	mu         sync.Mutex
	cond       *sync.Cond
	closed     bool
	closedAt   time.Time
	closeAcked bool
	finSentAt  time.Time
	opened     bool
	openAcked  bool
	openSentAt time.Time
	nextSeq    uint32 // 下一数据帧号
	sendQ      []Frame
	qN         int // 排队待发字节
	out        map[uint32]*outstanding
	outN       int // 已发未确认字节
	rto        time.Duration
}

type outstanding struct {
	f      Frame
	sentAt time.Time
}

func newTransmitter(sess *Session, id uint32, peer net.IP) *transmitter {
	tx := &transmitter{
		sess: sess,
		peer: peer,
		id:   id,
		rto:  rtoStart,
		out:  map[uint32]*outstanding{},
	}
	tx.cond = sync.NewCond(&tx.mu)
	return tx
}

// write 把 p 切块入队;未确认与排队字节合计达到窗口上限时阻塞(背压)。
func (tx *transmitter) write(p []byte) error {
	tx.mu.Lock()
	defer tx.mu.Unlock()
	if tx.closed {
		return ErrClosed
	}
	for len(p) > 0 {
		for tx.outN+tx.qN >= maxOutstanding {
			tx.cond.Wait()
			if tx.closed {
				return ErrClosed
			}
		}
		n := len(p)
		if n > maxChunk {
			n = maxChunk
		}
		// 一帧之后剩余的字节数在窗口内才入队,避免超大帧击穿窗口。
		tx.sendQ = append(tx.sendQ, Frame{Kind: FrameData, ID: tx.id, Seq: tx.nextSeq, Payload: p[:n]})
		tx.nextSeq++
		tx.qN += n
		p = p[n:]
	}
	return nil
}

// open 发出建流帧(仅 Dial 方);未收到确认前由 watch 重发。
func (tx *transmitter) open() {
	tx.mu.Lock()
	tx.opened = true
	tx.openSentAt = time.Now()
	tx.mu.Unlock()
	_ = tx.deliver(Frame{Kind: FrameOpen, ID: tx.id})
}

// onAck 累积确认 cum:seq < cum 的在途帧全部释放。
func (tx *transmitter) onAck(cum uint32) {
	tx.mu.Lock()
	tx.openAcked = true // 收到任何确认即说明对端已登记该流
	for seq := range tx.out {
		if seq < cum {
			tx.outN -= len(tx.out[seq].f.Payload)
			delete(tx.out, seq)
		}
	}
	if tx.outN == 0 {
		tx.rto = rtoStart
	}
	tx.cond.Broadcast()
	tx.mu.Unlock()
}

// ack 立即回一帧累积确认。
func (tx *transmitter) ack(cum uint32) {
	_ = tx.deliver(Frame{Kind: FrameAck, ID: tx.id, Ack: cum})
}

// closeAck 回一帧关闭确认。
func (tx *transmitter) closeAck(finSeq uint32) {
	_ = tx.deliver(Frame{Kind: FrameCloseAck, ID: tx.id, Ack: finSeq})
}

// onCloseAck 对端已确认关闭,停止重传 Close。
func (tx *transmitter) onCloseAck(cum uint32) {
	tx.mu.Lock()
	if cum >= tx.nextSeq {
		tx.closeAcked = true
	}
	tx.cond.Broadcast()
	tx.mu.Unlock()
}

// close 置关闭标志;Close 帧由 watch 在数据全部确认后补发。
func (tx *transmitter) close() {
	tx.mu.Lock()
	if !tx.closed {
		tx.closed = true
		tx.closedAt = time.Now()
		tx.cond.Broadcast()
	}
	tx.mu.Unlock()
}

// watch 是发送守护:每个节拍把排队帧送进窗口、重传超时帧,
// 关闭且数据清空后发 Close 并退出。
//
// 纪律:调用 Deliver 绝不持锁——投递可能同步触发对端回调链,
// 对端回执又会拿本结构的锁,持锁会死锁。
func (tx *transmitter) watch() {
	ticker := time.NewTicker(watchInterval)
	defer ticker.Stop()
	for {
		tx.mu.Lock()
		// 建流未确认:重发 Open,直到对端回任一确认。
		if tx.opened && !tx.openAcked && time.Since(tx.openSentAt) >= tx.rto {
			tx.openSentAt = time.Now()
			tx.rto = minDur(tx.rto*2, rtoMax)
			tx.mu.Unlock()
			_ = tx.deliver(Frame{Kind: FrameOpen, ID: tx.id})
			<-ticker.C
			continue
		}
		if tx.closed && tx.openAcked && len(tx.sendQ) == 0 && tx.outN == 0 {
			if tx.closeAcked {
				tx.mu.Unlock()
				tx.sess.deregister(tx.id)
				return
			}
			// 数据已全部确认,补发(或重发)Close,直到对端回 CloseAck。
			if tx.finSentAt.IsZero() || time.Since(tx.finSentAt) >= tx.rto {
				fin := Frame{Kind: FrameClose, ID: tx.id, Ack: tx.nextSeq}
				tx.finSentAt = time.Now()
				tx.mu.Unlock()
				_ = tx.deliver(fin)
				<-ticker.C
				continue
			}
		}
		if tx.closed && time.Since(tx.closedAt) > closeGrace {
			// 对端长时间不确认:放弃剩余数据,不再占着资源。
			tx.mu.Unlock()
			tx.sess.deregister(tx.id)
			return
		}
		var batch []Frame
		for len(tx.sendQ) > 0 && tx.outN < maxOutstanding {
			f := tx.sendQ[0]
			n := len(f.Payload)
			if tx.outN > 0 && tx.outN+n > maxOutstanding {
				break
			}
			tx.sendQ = tx.sendQ[1:]
			tx.qN -= n
			tx.out[f.Seq] = &outstanding{f: f, sentAt: time.Now()}
			tx.outN += n
			batch = append(batch, f)
		}
		now := time.Now()
		retrans := 0
		for _, o := range tx.out {
			if now.Sub(o.sentAt) >= tx.rto {
				o.sentAt = now
				batch = append(batch, o.f)
				retrans++
			}
		}
		if retrans > 0 {
			tx.rto = minDur(tx.rto*2, rtoMax)
		}
		tx.mu.Unlock()

		for _, f := range batch {
			_ = tx.deliver(f)
		}
		<-ticker.C
	}
}

// deliver 把帧交给传输层(不持锁)。
func (tx *transmitter) deliver(f Frame) error {
	return tx.sess.t.Deliver(tx.peer, packFrame(f))
}
