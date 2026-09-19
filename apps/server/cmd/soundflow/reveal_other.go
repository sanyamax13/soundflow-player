//go:build !windows

package main

import "fmt"

func revealInExplorer(path string) error {
	return fmt.Errorf("проводник есть только в Windows")
}

func openFolderInExplorer(path string) error {
	return fmt.Errorf("проводник есть только в Windows")
}
