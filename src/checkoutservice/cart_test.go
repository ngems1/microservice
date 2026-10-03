package main

import (
	"fmt"
	"testing"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/checkoutservice/genproto"
)

func TestCheckCartNotEmpty(t *testing.T) {
	cases := []struct {
		name  string
		items []*pb.CartItem
		empty bool
	}{
		{"no items", nil, true},
		{"only zero quantities", []*pb.CartItem{{ProductId: "6E92ZMYYFZ", Quantity: 0}}, true},
		{"one item", []*pb.CartItem{{ProductId: "OLJCESPC7Z", Quantity: 1}}, false},
		{"mixed", []*pb.CartItem{{ProductId: "A", Quantity: 0}, {ProductId: "B", Quantity: 2}}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := checkCartNotEmpty(c.items)
			if got := isEmptyCart(err); got != c.empty {
				t.Errorf("empty = %v, want %v (err %v)", got, c.empty, err)
			}
		})
	}
}

func TestIsEmptyCartThroughWrapping(t *testing.T) {
	if !isEmptyCart(fmt.Errorf("prepare order: %w", errEmptyCart)) {
		t.Error("a wrapped errEmptyCart should still be recognised")
	}
}
