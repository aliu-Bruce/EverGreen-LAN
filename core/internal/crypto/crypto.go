// Package crypto 承担隧道层的全部密码学。
// 原则:只用标准库原语;密钥成对派生,收发两侧各用一把,
// 从结构上排除 nonce 撞车的可能;长期身份绑定交给房间码,本包不掺和。
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"sync"
)

// nonceLen 是数据报帧里前缀 nonce 的长度,与 GCM 标准一致。
const nonceLen = 12

// Identity 是本端的长期密钥对。P0 直接落内存,P1 起与房间码绑定。
type Identity struct {
	priv *ecdh.PrivateKey
	Pub  []byte // 32 字节 X25519 公钥
}

// NewIdentity 生成全新身份。
func NewIdentity() (*Identity, error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("crypto: 生成密钥失败: %w", err)
	}
	return &Identity{priv: priv, Pub: priv.PublicKey().Bytes()}, nil
}

// Session 是一次握手后的对称会话。
// low 供发起方发送 / 响应方接收,high 相反:两侧永不共用同一把发送钥匙,
// 即使两侧并发发包,nonce 也不会撞车。
type Session struct {
	mu   sync.Mutex
	low  cipher.AEAD
	high cipher.AEAD
	tx   cipher.AEAD
	rx   cipher.AEAD
	txN  uint64
	rxN  uint64 // 已接收的最大序号 + 1,只增不减
}

// Exchange 完成一次密钥交换。isInitiator 标记本端是否发起方。
// 双方各持己方私钥与对方公钥,即可推出同一对方向密钥。
func Exchange(self *Identity, peerPub []byte, isInitiator bool) (*Session, error) {
	pub, err := ecdh.X25519().NewPublicKey(peerPub)
	if err != nil {
		return nil, fmt.Errorf("crypto: 对端公钥无效: %w", err)
	}
	secret, err := self.priv.ECDH(pub)
	if err != nil {
		return nil, fmt.Errorf("crypto: ECDH 失败: %w", err)
	}
	lowKey, err := hkdfKey(secret, "eglan/v1 dir=low")
	if err != nil {
		return nil, err
	}
	highKey, err := hkdfKey(secret, "eglan/v1 dir=high")
	if err != nil {
		return nil, err
	}
	low, err := aead(lowKey)
	if err != nil {
		return nil, err
	}
	high, err := aead(highKey)
	if err != nil {
		return nil, err
	}
	s := &Session{low: low, high: high}
	if isInitiator {
		s.tx, s.rx = low, high
	} else {
		s.tx, s.rx = high, low
	}
	return s, nil
}

// Seal 按发送计数器封一个包:nonce 作前缀,其后是密文与认证标签。
// 计数器永不回绕复用:会话级寿命远小于 2^64。
func (s *Session) Seal(pt []byte) []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	var nonce [nonceLen]byte
	binary.BigEndian.PutUint64(nonce[4:], s.txN)
	s.txN++
	return s.tx.Seal(nonce[:], nonce[:], pt, nil)
}

// Open 还原一个包。以"接收序号只增不减"抵御重放:
// 比历史最大序号新的包放行,旧的或重复的丢弃。
// 乱序到达的少量包视同普通丢包,交给上层 IP 栈自行处理;
// 序号写在 nonce 里不受保护,但伪造包过不了认证,不会污染计数。
func (s *Session) Open(frame []byte) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(frame) < nonceLen {
		return nil, fmt.Errorf("crypto: 包过短")
	}
	n := binary.BigEndian.Uint64(frame[4:nonceLen])
	if n < s.rxN {
		return nil, fmt.Errorf("crypto: 过期序号,疑似重放")
	}
	pt, err := s.rx.Open(nil, frame[:nonceLen], frame[nonceLen:], nil)
	if err != nil {
		return nil, fmt.Errorf("crypto: 解密失败: %w", err)
	}
	s.rxN = n + 1
	return pt, nil
}

// aead 由 32 字节密钥构造 AES-GCM。
func aead(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("crypto: 构造分组密码失败: %w", err)
	}
	return cipher.NewGCM(block)
}

// hkdfKey 按标准 HKDF-SHA256 从共享秘密派生 32 字节密钥。
// Extract:盐为空时按规范以哈希长度个零字节起算;Expand:单块足够。
func hkdfKey(secret []byte, info string) ([]byte, error) {
	prk := hmac.New(sha256.New, make([]byte, sha256.Size))
	prk.Write(secret)
	mac := hmac.New(sha256.New, prk.Sum(nil))
	mac.Write([]byte(info))
	mac.Write([]byte{1})
	return mac.Sum(nil), nil
}
