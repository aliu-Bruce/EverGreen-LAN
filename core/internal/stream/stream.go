// Package stream 在房间数据面上提供可靠双向字节流,供文件传输与插件宿主使用。
//
// 流帧为 best-effort 投递,可靠性(编号、累积确认、重传、滑窗)在本包内实现;
// 传输层只需提供 Deliver(成员IP, 帧字节)。帧格式见 codec.go。
package stream

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"net"
	"sync"
	"time"
)

var (
	ErrClosed  = errors.New("stream: 流已关闭")
	ErrNoRoute = errors.New("stream: 无成员路由")
	errDupOpen = errors.New("stream: 重复的建流帧")
)

// Delivery 是流帧投递层(mesh 侧:加密后按成员 IP 发送)。
type Delivery interface {
	Deliver(dst net.IP, data []byte) error
}

// Session 持有本端全部流,一个房间一个。
//
// 流号由发起方分配;双方同时发起时,随机高 16 位让两侧号段基本不重叠。
type Session struct {
	t         Delivery
	mu        sync.Mutex
	streams   map[uint32]*streamInstance
	nextID    uint32
	acceptCh  chan *streamInstance
	done      chan struct{}
	closeOnce sync.Once
}

func NewSession(t Delivery) *Session {
	var seed [4]byte
	_, _ = rand.Read(seed[:])
	return &Session{
		t:        t,
		streams:  map[uint32]*streamInstance{},
		nextID:   binary.BigEndian.Uint32(seed[:]) & 0xFFFF0000,
		acceptCh: make(chan *streamInstance, 16),
		done:     make(chan struct{}),
	}
}

func (s *Session) streamOf(id uint32) *streamInstance {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.streams[id]
}

// deregister 在流的发送守护完全结束后注销;之后到达的该流帧静默丢弃。
func (s *Session) deregister(id uint32) {
	s.mu.Lock()
	delete(s.streams, id)
	s.mu.Unlock()
}

// Dial 向成员 peer(房间内固定 IP)开一条可靠流。
func (s *Session) Dial(peer net.IP) (Stream, error) {
	if peer == nil || peer.IsUnspecified() {
		return nil, ErrNoRoute
	}
	s.mu.Lock()
	s.nextID++
	id := s.nextID
	if _, dup := s.streams[id]; dup {
		s.mu.Unlock()
		return nil, errDupOpen
	}
	st := newStreamInstance(s, id, peer)
	s.streams[id] = st
	s.mu.Unlock()

	go st.tx.watch()
	st.tx.open()
	return st, nil
}

// Accept 阻塞等待对端建流。会话关闭或超时返回错误。
func (s *Session) Accept() (Stream, error) {
	select {
	case st := <-s.acceptCh:
		return st, nil
	case <-s.done:
		return nil, ErrClosed
	case <-time.After(acceptTimeout):
		return nil, ErrNoRoute
	}
}

// Dispatch 是传输层收帧入口:payload 是解出的流帧。
func (s *Session) Dispatch(from net.IP, payload []byte) {
	f, ok := parseFrame(payload)
	if !ok {
		return
	}
	switch f.Kind {
	case FrameOpen:
		s.mu.Lock()
		if st, dup := s.streams[f.ID]; dup {
			s.mu.Unlock()
			st.tx.ack(0) // 对端没收到建流确认,重发建流帧后再次确认
			return
		}
		st := newStreamInstance(s, f.ID, from)
		s.streams[f.ID] = st
		s.mu.Unlock()
		select {
		case s.acceptCh <- st:
			go st.tx.watch()
			st.tx.ack(0) // 建流确认:发送方据此停止重发 Open
		default:
			// 接受队列已满:拒绝该流,避免无限堆积。
			s.mu.Lock()
			delete(s.streams, f.ID)
			s.mu.Unlock()
		}
	case FrameData:
		if st := s.streamOf(f.ID); st != nil {
			cum := st.rx.inData(f)
			st.tx.ack(cum)
		}
	case FrameAck:
		if st := s.streamOf(f.ID); st != nil {
			st.tx.onAck(f.Ack)
		}
	case FrameClose:
		if st := s.streamOf(f.ID); st != nil {
			st.rx.inClose(f.Ack)
			st.tx.ack(f.Ack)      // 数据全部收齐的最后确认
			st.tx.closeAck(f.Ack) // 让发送方停止重传 Close
		}
	case FrameCloseAck:
		if st := s.streamOf(f.ID); st != nil {
			st.tx.onCloseAck(f.Ack)
		}
	}
}

// Close 关闭全部流并清空登记;不等待对端应答,用于房间拆除。
func (s *Session) Close() {
	s.closeOnce.Do(func() {
		close(s.done)
	})
	s.mu.Lock()
	list := make([]*streamInstance, 0, len(s.streams))
	for _, st := range s.streams {
		list = append(list, st)
	}
	s.streams = map[uint32]*streamInstance{}
	s.mu.Unlock()
	for _, st := range list {
		st.closedOnce.Do(func() {
			st.tx.close()
			st.rx.close()
			close(st.done)
		})
	}
}

// Stream 是可靠双向字节流。
type Stream interface {
	Read(p []byte) (int, error)
	Write(p []byte) (int, error)
	Close() error
	// Peer 返回对端成员 IP(Dial 方得到目标,Accept 方得到来源)。
	Peer() string
	// Done 在流关闭后关闭。
	Done() <-chan struct{}
}

type streamInstance struct {
	id         uint32
	sess       *Session
	peerIP     net.IP
	done       chan struct{}
	rx         *receiver
	tx         *transmitter
	closedOnce sync.Once
}

func newStreamInstance(s *Session, id uint32, peer net.IP) *streamInstance {
	return &streamInstance{
		id:     id,
		sess:   s,
		peerIP: peer,
		done:   make(chan struct{}),
		rx:     newReceiver(),
		tx:     newTransmitter(s, id, peer),
	}
}

func (st *streamInstance) Peer() string {
	if st.peerIP == nil {
		return ""
	}
	return st.peerIP.String()
}

func (st *streamInstance) Done() <-chan struct{} { return st.done }

func (st *streamInstance) Read(p []byte) (int, error) { return st.rx.read(p) }

func (st *streamInstance) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if err := st.tx.write(p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (st *streamInstance) Close() error {
	st.closedOnce.Do(func() {
		st.tx.close()
		st.rx.close()
		close(st.done)
		// 登记保留到发送守护完成 Close 握手后再注销,否则回执会被丢弃。
	})
	return nil
}

var _ Stream = (*streamInstance)(nil)
