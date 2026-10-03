// Week 3: an order needs at least one item.
//
// The original checkout did not check this: submitting the checkout form with an
// empty cart (e.g. after going Back from a finished order) charged only the shipping
// fee and created an order with no items. inventoryservice rejects such an order,
// so it stayed PENDING and its event ended in the inventory dead-letter queue
// (caught by the CloudWatch alarm in Slack). Now checkout refuses it up front,
// before anything is charged.
package main

import (
	"errors"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/checkoutservice/genproto"
)

var errEmptyCart = errors.New("the cart is empty")

// checkCartNotEmpty returns errEmptyCart unless at least one item has a quantity.
func checkCartNotEmpty(items []*pb.CartItem) error {
	for _, it := range items {
		if it.GetQuantity() > 0 {
			return nil
		}
	}
	return errEmptyCart
}

func isEmptyCart(err error) bool { return errors.Is(err, errEmptyCart) }
