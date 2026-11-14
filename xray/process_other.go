//go:build !windows

package xray

import "os/exec"

func configureChildProcess(_ *exec.Cmd) {}
func attachChildLifetime(_ *exec.Cmd)   {}
