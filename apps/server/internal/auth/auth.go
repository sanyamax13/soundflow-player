package auth

import (
	"crypto/subtle"
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var ErrBadCredentials = errors.New("неверный логин или пароль")

// Auth выдаёт и проверяет пропуск (token). Один пользователь — Alex.
type Auth struct {
	login  string
	pass   string
	secret []byte
}

func New(login, pass string, secret []byte) *Auth {
	return &Auth{login: login, pass: pass, secret: secret}
}

// Login сверяет логин/пароль и возвращает подписанный пропуск.
// Срок жизни большой намеренно: телефон входит один раз и дальше работает офлайн.
func (a *Auth) Login(login, pass string) (string, error) {
	okLogin := subtle.ConstantTimeCompare([]byte(login), []byte(a.login)) == 1
	okPass := subtle.ConstantTimeCompare([]byte(pass), []byte(a.pass)) == 1
	if !okLogin || !okPass {
		return "", ErrBadCredentials
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.RegisteredClaims{
		Subject:   a.login,
		IssuedAt:  jwt.NewNumericDate(time.Now()),
		ExpiresAt: jwt.NewNumericDate(time.Now().AddDate(10, 0, 0)),
	})
	return tok.SignedString(a.secret)
}

// Verify проверяет подпись и срок пропуска, возвращает subject (логин).
func (a *Auth) Verify(token string) (string, error) {
	claims := &jwt.RegisteredClaims{}
	_, err := jwt.ParseWithClaims(token, claims, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, errors.New("неожиданный способ подписи")
		}
		return a.secret, nil
	})
	if err != nil {
		return "", err
	}
	return claims.Subject, nil
}
