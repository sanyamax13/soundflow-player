package auth

import "testing"

func TestLoginAndVerify(t *testing.T) {
	a := New("alex", "s3cret", []byte("test-secret"))

	tok, err := a.Login("alex", "s3cret")
	if err != nil {
		t.Fatalf("вход не прошёл: %v", err)
	}
	if tok == "" {
		t.Fatal("пустой пропуск")
	}

	sub, err := a.Verify(tok)
	if err != nil {
		t.Fatalf("проверка пропуска не прошла: %v", err)
	}
	if sub != "alex" {
		t.Fatalf("subject = %q, ждали alex", sub)
	}
}

func TestLoginRejectsBadPassword(t *testing.T) {
	a := New("alex", "s3cret", []byte("test-secret"))

	if _, err := a.Login("alex", "wrong"); err != ErrBadCredentials {
		t.Fatalf("ждали ErrBadCredentials, получили %v", err)
	}
	if _, err := a.Login("someoneelse", "s3cret"); err != ErrBadCredentials {
		t.Fatalf("ждали ErrBadCredentials для чужого логина, получили %v", err)
	}
}

func TestVerifyRejectsForeignSecret(t *testing.T) {
	a := New("alex", "s3cret", []byte("secret-a"))
	b := New("alex", "s3cret", []byte("secret-b"))

	tok, _ := a.Login("alex", "s3cret")
	if _, err := b.Verify(tok); err == nil {
		t.Fatal("пропуск с чужим ключом прошёл проверку")
	}
}
