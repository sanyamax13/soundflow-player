//go:build !windows

package diskspace

import "syscall"

// Free возвращает свободные и общие байты файловой системы, где лежит path.
func Free(path string) (free, total int64, err error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, err
	}
	bs := int64(st.Bsize)
	return int64(st.Bavail) * bs, int64(st.Blocks) * bs, nil
}
