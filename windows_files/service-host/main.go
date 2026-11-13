// x-ui-service hosts the 3x-ui panel and its Xray core as a Windows service.
package main

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
)

const serviceName = "3x-ui"

type host struct{ root string }

func (h *host) logf(format string, args ...any) {
	f, err := os.OpenFile(filepath.Join(h.root, "runtime", "log", "service.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	log.New(f, "", log.LstdFlags).Printf(format, args...)
}

func (h *host) prepare(logFile *os.File) error {
	bat := filepath.Join(h.root, "x-ui-manager.bat")
	cmd := exec.Command("cmd.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CmdLine:    `cmd.exe /d /s /c ""` + bat + `" prepare"`,
		HideWindow: true,
	}
	cmd.Dir = h.root
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	return cmd.Run()
}

// killOnCloseJob places pid in a job object that terminates every member when
// the returned handle is closed, so Xray cannot outlive the panel.
func killOnCloseJob(pid uint32) (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{
		BasicLimitInformation: windows.JOBOBJECT_BASIC_LIMIT_INFORMATION{
			LimitFlags: windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
		},
	}
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	handle, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, pid)
	if err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	defer windows.CloseHandle(handle)
	if err := windows.AssignProcessToJobObject(job, handle); err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	return job, nil
}

func killTree(pid int) {
	_ = exec.Command("taskkill.exe", "/PID", strconv.Itoa(pid), "/T", "/F").Run()
}

func (h *host) Execute(_ []string, requests <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	changes <- svc.Status{State: svc.StartPending}
	if err := os.MkdirAll(filepath.Join(h.root, "runtime", "log"), 0o755); err != nil {
		return false, 1
	}
	logFile, err := os.OpenFile(filepath.Join(h.root, "runtime", "log", "service.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return false, 1
	}
	defer logFile.Close()

	if err := h.prepare(logFile); err != nil {
		h.logf("prepare failed: %v", err)
		return false, 1
	}

	cmd := exec.Command(filepath.Join(h.root, "x-ui.exe"), "run")
	cmd.Dir = h.root
	cmd.Env = append(os.Environ(),
		"XUI_DB_FOLDER="+filepath.Join(h.root, "runtime", "db"),
		"XUI_LOG_FOLDER="+filepath.Join(h.root, "runtime", "log"),
		"XUI_BIN_FOLDER="+filepath.Join(h.root, "bin"),
		"XUI_DEBUG=false",
		"XUI_LOG_LEVEL=info",
	)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Start(); err != nil {
		h.logf("panel start failed: %v", err)
		return false, 1
	}
	panelPID := cmd.Process.Pid
	h.logf("panel started, pid %d", panelPID)

	job, err := killOnCloseJob(uint32(panelPID))
	if err != nil {
		h.logf("kill-on-close job unavailable: %v", err)
	}
	closeJob := func() {
		if job != 0 {
			_ = windows.CloseHandle(job)
			job = 0
		}
	}
	defer closeJob()

	changes <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	var once sync.Once
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	for {
		select {
		case request := <-requests:
			switch request.Cmd {
			case svc.Interrogate:
				changes <- request.CurrentStatus
			case svc.Stop, svc.Shutdown:
				changes <- svc.Status{State: svc.StopPending}
				once.Do(func() { killTree(panelPID) })
				<-done
				closeJob()
				h.logf("panel stopped")
				return false, 0
			}
		case err := <-done:
			closeJob()
			h.logf("panel exited: %v", err)
			return false, 0
		}
	}
}

func main() {
	exe, err := os.Executable()
	if err != nil {
		os.Exit(1)
	}
	runningAsService, err := svc.IsWindowsService()
	if err != nil || !runningAsService {
		os.Stderr.WriteString("x-ui-service must be started by the Windows service manager.\n")
		os.Exit(2)
	}
	if err := svc.Run(serviceName, &host{root: filepath.Dir(exe)}); err != nil {
		os.Exit(1)
	}
}
