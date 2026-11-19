package stream

import (
	"io"
	"sync"
)

// receiver 是有序提交端:把乱序到达的数据帧按 seq 落序,
// 供 Read 消费;FrameClose 带 finSeq,收齐全部数据后返回 EOF。
type receiver struct {
	mu      sync.Mutex
	cond    *sync.Cond
	buf     []byte            // 已按序、待读字节
	next    uint32            // 下一个期望的 seq(帧号)
	bySeq   map[uint32][]byte // 已到但尚未落序的帧
	closed  bool              // 本端硬关闭
	finSeq  uint32            // 对端声明发送的数据帧总数
	finRcvd bool
}

func newReceiver() *receiver {
	r := &receiver{bySeq: map[uint32][]byte{}}
	r.cond = sync.NewCond(&r.mu)
	return r
}

// inData 收入一帧并返回提交后的累积确认点(下一期望 seq)。
// 对端按该值裁剪重传队列。
func (r *receiver) inData(f Frame) (cum uint32) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return r.next
	}
	if f.Seq < r.next {
		return r.next // 重放帧:只回确认
	}
	if _, dup := r.bySeq[f.Seq]; !dup {
		r.bySeq[f.Seq] = f.Payload
		for {
			seg, ok := r.bySeq[r.next]
			if !ok {
				break
			}
			r.buf = append(r.buf, seg...)
			delete(r.bySeq, r.next)
			r.next++
		}
		r.cond.Broadcast()
	}
	return r.next
}

// inClose 对端声明发送结束:finSeq 为其数据帧总数。
func (r *receiver) inClose(finSeq uint32) {
	r.mu.Lock()
	r.finRcvd = true
	r.finSeq = finSeq
	r.cond.Broadcast()
	r.mu.Unlock()
}

// close 本端硬关闭:之后 Read 立即 EOF,不再收数据。
func (r *receiver) close() {
	r.mu.Lock()
	r.closed = true
	r.cond.Broadcast()
	r.mu.Unlock()
}

func (r *receiver) read(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for {
		if len(r.buf) > 0 {
			n := copy(p, r.buf)
			r.buf = r.buf[n:]
			return n, nil
		}
		if r.closed {
			return 0, io.EOF
		}
		if r.finRcvd && r.next >= r.finSeq {
			return 0, io.EOF
		}
		r.cond.Wait()
	}
}
