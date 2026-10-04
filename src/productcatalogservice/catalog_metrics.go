// Week 3: Prometheus metrics for the catalog's database/cache path.
//
// GET :9090/metrics (METRICS_PORT) in the Prometheus text format, written by hand
// so no client library is needed. Scraped by Prometheus (namespace "monitoring")
// through the pod's prometheus.io/* annotations; shown on the Grafana dashboard
// as the cache hit rate, MySQL loads and errors.
package main

import (
	"fmt"
	"io"
	"net/http"
	"time"
)

func (l *catalogLoader) writeMetrics(w io.Writer) {
	s := &l.stats
	fmt.Fprintln(w, "# HELP productcatalog_cache_requests_total Catalog requests by Redis cache result.")
	fmt.Fprintln(w, "# TYPE productcatalog_cache_requests_total counter")
	fmt.Fprintf(w, "productcatalog_cache_requests_total{result=\"hit\"} %d\n", s.hits.Load())
	fmt.Fprintf(w, "productcatalog_cache_requests_total{result=\"miss\"} %d\n", s.misses.Load())
	fmt.Fprintln(w, "# HELP productcatalog_mysql_loads_total Catalog reads from RDS MySQL (cache misses that succeeded).")
	fmt.Fprintln(w, "# TYPE productcatalog_mysql_loads_total counter")
	fmt.Fprintf(w, "productcatalog_mysql_loads_total %d\n", s.dbLoads.Load())
	fmt.Fprintln(w, "# HELP productcatalog_mysql_errors_total Failed catalog reads from RDS MySQL.")
	fmt.Fprintln(w, "# TYPE productcatalog_mysql_errors_total counter")
	fmt.Fprintf(w, "productcatalog_mysql_errors_total %d\n", s.dbErrors.Load())
	fmt.Fprintln(w, "# HELP productcatalog_redis_errors_total Failed Redis calls or unreadable cache entries.")
	fmt.Fprintln(w, "# TYPE productcatalog_redis_errors_total counter")
	fmt.Fprintf(w, "productcatalog_redis_errors_total %d\n", s.cacheErrors.Load())
	fmt.Fprintln(w, "# HELP productcatalog_fallback_total Requests served without fresh data, by source.")
	fmt.Fprintln(w, "# TYPE productcatalog_fallback_total counter")
	fmt.Fprintf(w, "productcatalog_fallback_total{source=\"last_good\"} %d\n", s.stale.Load())
	fmt.Fprintf(w, "productcatalog_fallback_total{source=\"products_json\"} %d\n", s.fallbacks.Load())
}

// serveMetrics runs the metrics endpoint until the process exits.
func (l *catalogLoader) serveMetrics(port string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		l.writeMetrics(w)
	})
	srv := &http.Server{Addr: ":" + port, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Infof("catalog metrics on :%s/metrics", port)
	if err := srv.ListenAndServe(); err != nil {
		log.WithError(err).Warn("catalog metrics endpoint stopped")
	}
}
