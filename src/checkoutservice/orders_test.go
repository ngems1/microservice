package main

import (
	"encoding/json"
	"testing"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/checkoutservice/genproto"
)

func TestNewOrderCreated(t *testing.T) {
	order := &pb.OrderResult{
		OrderId:            "o-1",
		ShippingTrackingId: "TRK-1",
		Items: []*pb.OrderItem{
			{Item: &pb.CartItem{ProductId: "OLJCESPC7Z", Quantity: 2}},
			{Item: &pb.CartItem{ProductId: "6E92ZMYYFZ", Quantity: 3}},
			{Item: nil}, // ignored
		},
	}
	total := &pb.Money{CurrencyCode: "USD", Units: 64, Nanos: 950000000}

	ev := newOrderCreated(order, "a@b.c", total)
	if ev.Version != "1" || ev.OrderID != "o-1" || ev.Email != "a@b.c" || ev.ShippingTrackingID != "TRK-1" {
		t.Fatalf("unexpected header: %+v", ev)
	}
	if len(ev.Items) != 2 || ev.Items[1].ProductID != "6E92ZMYYFZ" || ev.Items[1].Quantity != 3 {
		t.Fatalf("unexpected items: %+v", ev.Items)
	}

	// The consumers (inventoryservice, order-status Lambda) read these exact keys.
	b, err := json.Marshal(ev)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"version", "orderId", "email", "items", "total", "shippingTrackingId"} {
		if _, ok := m[k]; !ok {
			t.Errorf("missing key %q in %s", k, b)
		}
	}
	line := m["items"].([]any)[0].(map[string]any)
	if line["productId"] != "OLJCESPC7Z" || line["quantity"].(float64) != 2 {
		t.Errorf("unexpected line: %v", line)
	}
	tot := m["total"].(map[string]any)
	if tot["currencyCode"] != "USD" || tot["units"].(float64) != 64 {
		t.Errorf("unexpected total: %v", tot)
	}
}

func TestOrderLinesEmpty(t *testing.T) {
	if got := orderLines(nil); len(got) != 0 {
		t.Fatalf("expected no lines, got %v", got)
	}
}
