package appsettings

import (
	"bufio"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha512"
	"encoding/base64"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// Вход в Web UI qBittorrent для качалки. qBittorrent хранит не пароль, а его хеш PBKDF2-SHA512
// (100 000 повторов, соль 16 байт, ключ 64 байта) строкой «@ByteArray(соль:хеш)» в base64.

// QbtPasswordHash — значение WebUI\Password_PBKDF2 для пароля pass.
func QbtPasswordHash(pass string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key, err := pbkdf2.Key(sha512.New, pass, salt, 100000, 64)
	if err != nil {
		return "", err
	}
	return `"@ByteArray(` + base64.StdEncoding.EncodeToString(salt) + ":" + base64.StdEncoding.EncodeToString(key) + `)"`, nil
}

// RandomSecret — случайная строка для паролей и ключей (буквы и цифры).
func RandomSecret(n int) string {
	const abc = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, n)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = abc[int(b[i])%len(abc)]
	}
	return string(b)
}

// WriteQbtWebUI — включить в qBittorrent.ini Web UI для этого компьютера с логином user и паролем
// pass. Остальные настройки файла сохраняются как были; нет файла — создаётся.
func WriteQbtWebUI(ini, user, pass string) error {
	hash, err := QbtPasswordHash(pass)
	if err != nil {
		return err
	}
	want := map[string]string{
		`WebUI\Enabled`:         "true",
		`WebUI\Address`:         "127.0.0.1",
		`WebUI\Port`:            "8080",
		`WebUI\Username`:        user,
		`WebUI\Password_PBKDF2`: hash,
	}
	var lines []string
	if f, err := os.Open(ini); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			lines = append(lines, sc.Text())
		}
		f.Close()
	}
	out := setIniSection(lines, "Preferences", want)
	out = setIniSection(out, "LegalNotice", map[string]string{"Accepted": "true"})
	if err := os.MkdirAll(filepath.Dir(ini), 0o755); err != nil {
		return err
	}
	return os.WriteFile(ini, []byte(strings.Join(out, "\r\n")+"\r\n"), 0o600)
}

// setIniSection — выставить ключи в секции [name]: найденные заменить, недостающие дописать в конец
// секции; секции нет — добавить её в конец файла.
func setIniSection(lines []string, name string, kv map[string]string) []string {
	head := "[" + name + "]"
	start, end := -1, len(lines)
	for i, l := range lines {
		t := strings.TrimSpace(l)
		if t == head {
			start = i
			continue
		}
		if start >= 0 && strings.HasPrefix(t, "[") && i > start {
			end = i
			break
		}
	}
	left := map[string]string{}
	for k, v := range kv {
		left[k] = v
	}
	if start < 0 {
		out := append([]string{}, lines...)
		if len(out) > 0 && strings.TrimSpace(out[len(out)-1]) != "" {
			out = append(out, "")
		}
		out = append(out, head)
		for _, k := range slices.Sorted(maps.Keys(left)) {
			out = append(out, k+"="+left[k])
		}
		return out
	}
	out := append([]string{}, lines[:start+1]...)
	for _, l := range lines[start+1 : end] {
		if k, _, ok := strings.Cut(l, "="); ok {
			if v, hit := left[strings.TrimSpace(k)]; hit {
				out = append(out, strings.TrimSpace(k)+"="+v)
				delete(left, strings.TrimSpace(k))
				continue
			}
		}
		out = append(out, l)
	}
	// недостающие — перед пустыми строками в конце секции
	tail := len(out)
	for tail > start+1 && strings.TrimSpace(out[tail-1]) == "" {
		tail--
	}
	var add []string
	for _, k := range slices.Sorted(maps.Keys(left)) {
		add = append(add, k+"="+left[k])
	}
	out = append(out[:tail], append(add, out[tail:]...)...)
	return append(out, lines[end:]...)
}
