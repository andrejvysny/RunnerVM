package fleet

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"fmt"
	"strings"

	"golang.org/x/crypto/ssh"
)

const keyComment = "runnervm-fleeting"

// keyPair is a key installed (or about to be) on one instance.
type keyPair struct {
	authorized string
	pem        []byte
}

// generateKey returns a fresh ed25519 keypair as an OpenSSH authorized_keys
// line (single line, no trailing newline) and a PEM-encoded private key.
func generateKey() (authorizedKey string, privatePEM []byte, err error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", nil, fmt.Errorf("generate ed25519 key: %w", err)
	}
	sshPub, err := ssh.NewPublicKey(pub)
	if err != nil {
		return "", nil, fmt.Errorf("encode public key: %w", err)
	}
	block, err := ssh.MarshalPrivateKey(priv, keyComment)
	if err != nil {
		return "", nil, fmt.Errorf("encode private key: %w", err)
	}
	line := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPub))) + " " + keyComment
	return line, pem.EncodeToMemory(block), nil
}
