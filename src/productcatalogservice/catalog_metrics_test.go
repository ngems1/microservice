package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

func TestWriteMetrics(t *testing.T) {
	l := newTestLoader(&fakeSource{ps: dbProducts()}, &fakeCache{data: map[string][]byte{}})
	ctx := context.Background()
	l.products(ctx) // miss + MySQL load
	l.products(ctx) // hit
	l.products(ctx) // hit

	var buf bytes.Buffer
	l.writeMetrics(&buf)
	out := buf.String()
	for _, want := range []string{
		`productcatalog_cache_requests_total{result="hit"} 2`,
		`productcatalog_cache_requests_total{result="miss"} 1`,
		`productcatalog_mysql_loads_total 1`,
		`productcatalog_mysql_errors_total 0`,
		`# TYPE productcatalog_cache_requests_total counter`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("metrics output is missing %q:\n%s", want, out)
		}
	}
}
