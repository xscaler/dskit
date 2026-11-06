package xstenant

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

type metrics struct {
	generation    prometheus.Gauge
	published     prometheus.Gauge
	lastSuccess   prometheus.Gauge
	fetchFailures *prometheus.CounterVec
}

func newMetrics(reg prometheus.Registerer) *metrics {
	return &metrics{
		generation: promauto.With(reg).NewGauge(prometheus.GaugeOpts{
			Name: "xscaler_admin_store_generation",
			Help: "Generation of the admin store snapshot being served.",
		}),
		published: promauto.With(reg).NewGauge(prometheus.GaugeOpts{
			Name: "xscaler_admin_store_published_timestamp_seconds",
			Help: "Publish time of the admin store snapshot being served.",
		}),
		lastSuccess: promauto.With(reg).NewGauge(prometheus.GaugeOpts{
			Name: "xscaler_admin_store_last_success_timestamp_seconds",
			Help: "Time of the last poll that read a consistent manifest.",
		}),
		fetchFailures: promauto.With(reg).NewCounterVec(prometheus.CounterOpts{
			Name: "xscaler_admin_store_fetch_failures_total",
			Help: "Admin store fetches or updates that failed, by object and reason.",
		}, []string{"object", "reason"}),
	}
}
