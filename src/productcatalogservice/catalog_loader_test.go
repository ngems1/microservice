package main

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/productcatalogservice/genproto"
)

type fakeSource struct {
	mu    sync.Mutex
	ps    []*pb.Product
	err   error
	calls int
}

func (f *fakeSource) LoadProducts(context.Context) ([]*pb.Product, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	return f.ps, f.err
}

type fakeCache struct {
	mu     sync.Mutex
	data   map[string][]byte
	getErr error
	setErr error
	ttl    time.Duration
}

func (f *fakeCache) Get(_ context.Context, key string) ([]byte, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.getErr != nil {
		return nil, false, f.getErr
	}
	v, ok := f.data[key]
	return v, ok, nil
}

func (f *fakeCache) Set(_ context.Context, key string, v []byte, ttl time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.setErr != nil {
		return f.setErr
	}
	f.data[key], f.ttl = v, ttl
	return nil
}

func dbProducts() []*pb.Product {
	return []*pb.Product{
		{Id: "OLJCESPC7Z", Name: "Sunglasses", PriceUsd: &pb.Money{CurrencyCode: "USD", Units: 19, Nanos: 990000000}, Categories: []string{"accessories"}},
		{Id: "6E92ZMYYFZ", Name: "Mug", PriceUsd: &pb.Money{CurrencyCode: "USD", Units: 8, Nanos: 990000000}},
	}
}

func jsonProducts() []*pb.Product { return []*pb.Product{{Id: "FROMJSON", Name: "From products.json"}} }

func newTestLoader(src productSource, cache cacheStore) *catalogLoader {
	l := &catalogLoader{source: src, ttl: 5 * time.Minute, fallback: jsonProducts,
		encode: encodeProducts, decode: decodeProducts}
	if cache != nil {
		l.cache = cache
	}
	return l
}

func TestMissLoadsMySQLAndFillsCache(t *testing.T) {
	src, cache := &fakeSource{ps: dbProducts()}, &fakeCache{data: map[string][]byte{}}
	l := newTestLoader(src, cache)

	ps := l.products(context.Background())
	if len(ps) != 2 || ps[0].Name != "Sunglasses" || ps[0].PriceUsd.Units != 19 {
		t.Fatalf("unexpected catalog %v", ps)
	}
	if _, ok := cache.data[catalogCacheKey]; !ok || cache.ttl != 5*time.Minute {
		t.Fatalf("catalog not cached with the TTL (ttl=%v)", cache.ttl)
	}
	if l.stats.misses.Load() != 1 || l.stats.dbLoads.Load() != 1 {
		t.Errorf("misses=%d loads=%d, want 1 and 1", l.stats.misses.Load(), l.stats.dbLoads.Load())
	}
}

func TestHitDoesNotTouchMySQL(t *testing.T) {
	src, cache := &fakeSource{ps: dbProducts()}, &fakeCache{data: map[string][]byte{}}
	l := newTestLoader(src, cache)
	ctx := context.Background()

	l.products(ctx) // miss: fills the cache
	for i := 0; i < 5; i++ {
		if ps := l.products(ctx); len(ps) != 2 || ps[1].Name != "Mug" {
			t.Fatalf("hit returned %v", ps)
		}
	}
	if src.calls != 1 {
		t.Errorf("MySQL called %d times, want 1 (then cache hits)", src.calls)
	}
	if l.stats.hits.Load() != 5 {
		t.Errorf("hits = %d, want 5", l.stats.hits.Load())
	}
}

func TestExpiredEntryReloadsNewPrice(t *testing.T) {
	src, cache := &fakeSource{ps: dbProducts()}, &fakeCache{data: map[string][]byte{}}
	l := newTestLoader(src, cache)
	ctx := context.Background()
	l.products(ctx)

	// price changed in MySQL, then the cache entry expires
	src.ps = []*pb.Product{{Id: "OLJCESPC7Z", Name: "Sunglasses", PriceUsd: &pb.Money{CurrencyCode: "USD", Units: 15}}}
	delete(cache.data, catalogCacheKey)

	if ps := l.products(ctx); ps[0].PriceUsd.Units != 15 {
		t.Fatalf("after expiry got price %d, want the new 15", ps[0].PriceUsd.Units)
	}
}

func TestRedisDownReadsMySQL(t *testing.T) {
	src := &fakeSource{ps: dbProducts()}
	cache := &fakeCache{data: map[string][]byte{}, getErr: errors.New("connection refused"), setErr: errors.New("connection refused")}
	l := newTestLoader(src, cache)
	if ps := l.products(context.Background()); len(ps) != 2 {
		t.Fatalf("Redis down: got %v, want the MySQL catalog", ps)
	}
	if l.stats.cacheErrors.Load() == 0 {
		t.Error("Redis errors not counted")
	}
}

func TestMySQLDownServesLastGoodCatalog(t *testing.T) {
	src := &fakeSource{ps: dbProducts()}
	l := newTestLoader(src, nil) // no cache: every request reads MySQL
	ctx := context.Background()
	l.products(ctx)

	src.err = errors.New("i/o timeout")
	if ps := l.products(ctx); len(ps) != 2 || ps[0].Id != "OLJCESPC7Z" {
		t.Fatalf("MySQL down: got %v, want the last good catalog", ps)
	}
	if l.stats.stale.Load() != 1 {
		t.Errorf("stale = %d, want 1", l.stats.stale.Load())
	}
}

func TestEverythingDownServesProductsJSON(t *testing.T) {
	src := &fakeSource{err: errors.New("no route to host")}
	cache := &fakeCache{data: map[string][]byte{}, getErr: errors.New("connection refused")}
	l := newTestLoader(src, cache)
	if ps := l.products(context.Background()); len(ps) != 1 || ps[0].Id != "FROMJSON" {
		t.Fatalf("got %v, want the products.json fallback", ps)
	}
}

func TestEmptyTableIsTreatedAsFailure(t *testing.T) {
	l := newTestLoader(&fakeSource{ps: nil}, nil)
	if ps := l.products(context.Background()); len(ps) != 1 || ps[0].Id != "FROMJSON" {
		t.Fatalf("empty table: got %v, want the products.json fallback", ps)
	}
}

func TestCorruptCacheEntryReloads(t *testing.T) {
	src := &fakeSource{ps: dbProducts()}
	cache := &fakeCache{data: map[string][]byte{catalogCacheKey: []byte("not json")}}
	l := newTestLoader(src, cache)
	if ps := l.products(context.Background()); len(ps) != 2 {
		t.Fatalf("corrupt cache: got %v, want the MySQL catalog", ps)
	}
	if src.calls != 1 {
		t.Errorf("MySQL calls = %d, want 1", src.calls)
	}
}

func TestEncodeDecodeRoundTrip(t *testing.T) {
	data, err := encodeProducts(dbProducts())
	if err != nil {
		t.Fatal(err)
	}
	ps, err := decodeProducts(data)
	if err != nil || len(ps) != 2 || ps[0].PriceUsd.Nanos != 990000000 || ps[0].Categories[0] != "accessories" {
		t.Fatalf("round trip got %v (err %v)", ps, err)
	}
}

func TestSplitCategories(t *testing.T) {
	got := splitCategories("clothing, tops,,")
	if len(got) != 2 || got[0] != "clothing" || got[1] != "tops" {
		t.Errorf("got %q", got)
	}
}

func TestServiceUsesLoader(t *testing.T) {
	svc := &productCatalog{loader: newTestLoader(&fakeSource{ps: dbProducts()}, &fakeCache{data: map[string][]byte{}})}
	p, err := svc.GetProduct(context.Background(), &pb.GetProductRequest{Id: "6E92ZMYYFZ"})
	if err != nil || p.Name != "Mug" {
		t.Fatalf("GetProduct via loader: %v, %v", p, err)
	}
}
