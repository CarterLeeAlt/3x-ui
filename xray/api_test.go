package xray

import (
	"context"
	"strings"
	"testing"

	"github.com/xtls/xray-core/app/proxyman/command"
	"github.com/xtls/xray-core/proxy/shadowsocks_2022"
	"google.golang.org/grpc"
)

type accountCapturingHandler struct {
	command.HandlerServiceClient
	request *command.AlterInboundRequest
}

func (handler *accountCapturingHandler) AlterInbound(_ context.Context, request *command.AlterInboundRequest, _ ...grpc.CallOption) (*command.AlterInboundResponse, error) {
	handler.request = request
	return &command.AlterInboundResponse{}, nil
}

func TestAddUserShadowsocks2022Account(t *testing.T) {
	handler := &accountCapturingHandler{}
	var client command.HandlerServiceClient = handler
	api := XrayAPI{HandlerServiceClient: &client}
	password := "AQEBAQEBAQEBAQEBAQEBAQ=="
	if err := api.AddUser("shadowsocks", "ss2022", map[string]any{
		"email": "alice@example.com", "cipher": "2022-blake3-aes-128-gcm", "password": password,
	}); err != nil {
		t.Fatal(err)
	}
	message, err := handler.request.Operation.GetInstance()
	if err != nil {
		t.Fatal(err)
	}
	operation, ok := message.(*command.AddUserOperation)
	if !ok {
		t.Fatalf("unexpected operation type %T", message)
	}
	message, err = operation.User.Account.GetInstance()
	if err != nil {
		t.Fatal(err)
	}
	account, ok := message.(*shadowsocks_2022.Account)
	if !ok || account.Key != password {
		t.Fatalf("unexpected Shadowsocks 2022 account: %T %v", message, message)
	}
	if operation.User.Email != "alice@example.com" {
		t.Fatalf("unexpected email %q", operation.User.Email)
	}
	if _, err := operation.User.ToMemoryUser(); err != nil {
		t.Fatalf("Xray cannot decode the user account: %v", err)
	}
}

func TestGetRequiredUserString_Present(t *testing.T) {
	user := map[string]any{"email": "alice@example.com"}
	got, err := getRequiredUserString(user, "email")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "alice@example.com" {
		t.Fatalf("got %q, want %q", got, "alice@example.com")
	}
}

func TestGetRequiredUserString_Missing(t *testing.T) {
	user := map[string]any{}
	if _, err := getRequiredUserString(user, "email"); err == nil {
		t.Fatal("expected error for missing key")
	}
}

func TestGetRequiredUserString_NilValue(t *testing.T) {
	user := map[string]any{"email": nil}
	if _, err := getRequiredUserString(user, "email"); err == nil {
		t.Fatal("expected error for nil value")
	}
}

func TestGetRequiredUserString_WrongType(t *testing.T) {
	user := map[string]any{"email": 42}
	_, err := getRequiredUserString(user, "email")
	if err == nil {
		t.Fatal("expected error for non-string value")
	}
	if !strings.Contains(err.Error(), "invalid type") {
		t.Fatalf("expected %q in error, got: %v", "invalid type", err)
	}
}

func TestGetOptionalUserString_Present(t *testing.T) {
	user := map[string]any{"flow": "xtls-rprx-vision"}
	got, err := getOptionalUserString(user, "flow")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "xtls-rprx-vision" {
		t.Fatalf("got %q, want %q", got, "xtls-rprx-vision")
	}
}

func TestGetOptionalUserString_MissingReturnsEmptyNoError(t *testing.T) {
	user := map[string]any{}
	got, err := getOptionalUserString(user, "flow")
	if err != nil {
		t.Fatalf("unexpected error for missing optional field: %v", err)
	}
	if got != "" {
		t.Fatalf("got %q, want empty string", got)
	}
}

func TestGetOptionalUserString_NilReturnsEmptyNoError(t *testing.T) {
	user := map[string]any{"flow": nil}
	got, err := getOptionalUserString(user, "flow")
	if err != nil {
		t.Fatalf("unexpected error for nil optional field: %v", err)
	}
	if got != "" {
		t.Fatalf("got %q, want empty string", got)
	}
}

func TestGetOptionalUserString_WrongTypeErrors(t *testing.T) {
	user := map[string]any{"flow": []string{"a", "b"}}
	if _, err := getOptionalUserString(user, "flow"); err == nil {
		t.Fatal("expected error for non-string optional value")
	}
}
