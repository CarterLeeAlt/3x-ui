package service

import (
	"runtime"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/web/entity"
)

func TestWindowsPanelLoopbackPolicy(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows management endpoint policy")
	}
	service := SettingService{}
	listen, err := service.GetListen()
	if err != nil || listen != "127.0.0.1" {
		t.Fatalf("unexpected listener %q: %v", listen, err)
	}
	for _, address := range []string{"", "0.0.0.0", "::", "192.168.1.10"} {
		if err := service.SetListen(address); err == nil {
			t.Fatalf("SetListen accepted %q", address)
		}
		if err := service.UpdateAllSetting(&entity.AllSetting{WebListen: address}); err == nil {
			t.Fatalf("UpdateAllSetting accepted %q", address)
		}
	}
}
