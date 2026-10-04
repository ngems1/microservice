"""Stress test for the Online Boutique (Locust 2.16), used by deploy/load-test.sh MODE=stress.

Same shopper behaviour as src/loadgenerator/locustfile.py (browse, cart, currency,
checkout), but with short pauses and a STEPPED ramp-up: every STEP_SECONDS the number
of shoppers grows by STEP_USERS, up to MAX_USERS, until RUN_SECONDS. Watching Grafana
during the ramp shows at which load latency and errors start to climb (the breaking point).

Several pods run this file in parallel (a Kubernetes Job with parallelism N); the
workflow divides the users between them. Mounted from a ConfigMap: no image rebuild.
"""
import os
import random

from locust import HttpUser, LoadTestShape, TaskSet, between

PRODUCTS = ['0PUK6V6EV0', '1YMWWN1N4O', '2ZYFJ3GM2N', '66VCHSJNUP', '6E92ZMYYFZ',
            '9SIQT8TOJO', 'L9ECAV7KIM', 'LS4PSXUNUM', 'OLJCESPC7Z']


def index(l):
    l.client.get("/")


def set_currency(l):
    l.client.post("/setCurrency", {'currency_code': random.choice(['EUR', 'USD', 'JPY', 'CAD'])})


def browse_product(l):
    l.client.get("/product/" + random.choice(PRODUCTS), name="/product/[id]")


def view_cart(l):
    l.client.get("/cart")


def add_to_cart(l):
    product = random.choice(PRODUCTS)
    l.client.get("/product/" + product, name="/product/[id]")
    l.client.post("/cart", {'product_id': product, 'quantity': random.choice([1, 2, 3])})


def checkout(l):
    add_to_cart(l)
    l.client.post("/cart/checkout", {
        'email': 'stress@example.com',
        'street_address': '1600 Amphitheatre Parkway', 'zip_code': '94043',
        'city': 'Mountain View', 'state': 'CA', 'country': 'United States',
        'credit_card_number': '4432-8015-6152-0454', 'credit_card_expiration_month': '1',
        'credit_card_expiration_year': '2039', 'credit_card_cvv': '672',
    })


class ShopperBehavior(TaskSet):
    def on_start(self):
        index(self)

    tasks = {index: 1, set_currency: 2, browse_product: 10, add_to_cart: 2, view_cart: 3, checkout: 1}


class Shopper(HttpUser):
    tasks = [ShopperBehavior]
    wait_time = between(0.5, 2)   # busy shoppers: ~1 request per second each


class StepLoad(LoadTestShape):
    """+STEP_USERS shoppers every STEP_SECONDS, up to MAX_USERS, stop after RUN_SECONDS."""
    step_users = int(os.environ.get("STEP_USERS", "10"))
    step_seconds = int(os.environ.get("STEP_SECONDS", "60"))
    max_users = int(os.environ.get("MAX_USERS", "100"))
    run_seconds = int(os.environ.get("RUN_SECONDS", "900"))

    def tick(self):
        t = self.get_run_time()
        if t > self.run_seconds:
            return None
        users = min(self.max_users, (int(t // self.step_seconds) + 1) * self.step_users)
        return users, max(1, self.step_users)
