//go:build windows

package xray

import (
	"os/exec"
	"sync"
	"syscall"
	"unsafe"

	"github.com/mhsanaei/3x-ui/v2/logger"
	"golang.org/x/sys/windows"
)

var (
	killOnExitJobOnce sync.Once
	killOnExitJob     windows.Handle
	killOnExitJobErr  error
)

func configureChildProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
}

func attachChildLifetime(cmd *exec.Cmd) {
	killOnExitJobOnce.Do(func() {
		handle, err := windows.CreateJobObject(nil, nil)
		if err != nil {
			killOnExitJobErr = err
			return
		}
		info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{
			BasicLimitInformation: windows.JOBOBJECT_BASIC_LIMIT_INFORMATION{LimitFlags: windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE},
		}
		_, err = windows.SetInformationJobObject(handle, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info)))
		if err != nil {
			windows.CloseHandle(handle)
			killOnExitJobErr = err
			return
		}
		killOnExitJob = handle
	})
	if killOnExitJobErr != nil {
		logger.Warning("xray: kill-on-exit job unavailable:", killOnExitJobErr)
		return
	}
	handle, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(cmd.Process.Pid))
	if err != nil {
		logger.Warning("xray: OpenProcess for job attach failed:", err)
		return
	}
	defer windows.CloseHandle(handle)
	if err := windows.AssignProcessToJobObject(killOnExitJob, handle); err != nil {
		logger.Warning("xray: AssignProcessToJobObject failed:", err)
	}
}
