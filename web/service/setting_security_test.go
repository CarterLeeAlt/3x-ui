package service

import (
	"path/filepath"
	"runtime"
	"testing"

	"github.com/mhsanaei/3x-ui/v3/database"
	"github.com/mhsanaei/3x-ui/v3/database/model"
)

func setupSettingTestDB(t *testing.T) {
	t.Helper()
	if err := database.InitDB(filepath.Join(t.TempDir(), "x-ui.db")); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := database.CloseDB(); err != nil {
			t.Fatal(err)
		}
	})
}

func TestGetAllSettingViewRedactsSecrets(t *testing.T) {
	setupSettingTestDB(t)
	s := &SettingService{}
	if err := s.saveSetting("tgBotToken", "telegram-secret"); err != nil {
		t.Fatal(err)
	}
	if err := s.saveSetting("twoFactorToken", "totp-secret"); err != nil {
		t.Fatal(err)
	}
	if err := s.saveSetting("ldapPassword", "ldap-secret"); err != nil {
		t.Fatal(err)
	}
	if err := database.GetDB().Create(&model.ApiToken{Name: "test", Token: "api-secret", Enabled: true}).Error; err != nil {
		t.Fatal(err)
	}

	view, err := s.GetAllSettingView()
	if err != nil {
		t.Fatal(err)
	}
	if view.TgBotToken != "" || view.TwoFactorToken != "" || view.LdapPassword != "" {
		t.Fatalf("settings view leaked secrets: %#v", view)
	}
	if !view.HasTgBotToken || !view.HasTwoFactorToken || !view.HasLdapPassword || !view.HasApiToken {
		t.Fatalf("settings view did not report configured secret flags: %#v", view)
	}
}

func TestUpdateAllSettingPreservesRedactedSecrets(t *testing.T) {
	setupSettingTestDB(t)
	s := &SettingService{}
	if err := s.saveSetting("tgBotToken", "telegram-secret"); err != nil {
		t.Fatal(err)
	}
	if err := s.saveSetting("ldapPassword", "ldap-secret"); err != nil {
		t.Fatal(err)
	}
	if err := s.saveSetting("twoFactorEnable", "true"); err != nil {
		t.Fatal(err)
	}
	if err := s.saveSetting("twoFactorToken", "totp-secret"); err != nil {
		t.Fatal(err)
	}

	view, err := s.GetAllSettingView()
	if err != nil {
		t.Fatal(err)
	}
	settings := &view.AllSetting
	if err := s.UpdateAllSetting(settings); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.GetTgBotToken(); got != "telegram-secret" {
		t.Fatalf("tg token = %q, want preserved secret", got)
	}
	if got, _ := s.GetLdapPassword(); got != "ldap-secret" {
		t.Fatalf("ldap password = %q, want preserved secret", got)
	}
	if got, _ := s.GetTwoFactorToken(); got != "totp-secret" {
		t.Fatalf("2fa token = %q, want preserved secret", got)
	}
}

func TestSanitizePublicHTTPURLBlocksPrivateAddressUnlessAllowed(t *testing.T) {
	if _, err := SanitizePublicHTTPURL("http://127.0.0.1:8080/hook", false); err == nil {
		t.Fatal("expected localhost URL to be blocked")
	}
	if got, err := SanitizePublicHTTPURL("http://127.0.0.1:8080/hook", true); err != nil || got != "http://127.0.0.1:8080/hook" {
		t.Fatalf("allowPrivate result = %q, %v", got, err)
	}
}

func TestPanelListenPlatformPolicy(t *testing.T) {
	setupSettingTestDB(t)
	s := &SettingService{}
	if err := s.saveSetting("webListen", "0.0.0.0"); err != nil {
		t.Fatal(err)
	}
	want := "0.0.0.0"
	if runtime.GOOS == "windows" {
		want = "127.0.0.1"
	}
	if got, err := s.GetListen(); err != nil || got != want {
		t.Fatalf("listen = %q, %v; want %q", got, err, want)
	}
	view, err := s.GetAllSettingView()
	if err != nil {
		t.Fatal(err)
	}
	if view.WebListen != want {
		t.Fatalf("incorrect listen view: %q", view.WebListen)
	}
	for _, address := range []string{"", "0.0.0.0", "::1", "192.0.2.1"} {
		err := s.SetListen(address)
		if runtime.GOOS == "windows" && err == nil {
			t.Fatalf("accepted Windows listen address %q", address)
		}
		if runtime.GOOS != "windows" && err != nil {
			t.Fatal(err)
		}
	}
	if runtime.GOOS == "windows" {
		view.WebListen = "0.0.0.0"
		if err := s.UpdateAllSetting(&view.AllSetting); err == nil {
			t.Fatal("settings API accepted a non-loopback listen address")
		}
	}
	if err := s.SetListen("127.0.0.1"); err != nil {
		t.Fatal(err)
	}
	if got, err := s.GetSubListen(); err != nil || got != "" {
		t.Fatalf("subscription binding was changed: %q, %v", got, err)
	}
}
