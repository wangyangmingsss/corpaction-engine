import http from 'http';

interface MetricEntry {
  name: string;
  help: string;
  type: string;
  value: number;
  labels?: Record<string, string>;
}

export class MetricsRegistry {
  private metrics: Map<string, MetricEntry[]> = new Map();

  counter(name: string, help: string, labels?: Record<string, string>): void {
    const key = this.key(name, labels);
    const existing = this.metrics.get(key);
    if (existing && existing.length > 0) {
      existing[0].value += 1;
    } else {
      this.metrics.set(key, [{ name, help, type: 'counter', value: 1, labels }]);
    }
  }

  gauge(name: string, help: string, value: number, labels?: Record<string, string>): void {
    const key = this.key(name, labels);
    this.metrics.set(key, [{ name, help, type: 'gauge', value, labels }]);
  }

  histogram(name: string, help: string, value: number, labels?: Record<string, string>): void {
    const key = this.key(name, labels);
    const existing = this.metrics.get(key);
    if (!existing) {
      this.metrics.set(key, [{ name, help, type: 'histogram', value, labels }]);
    } else {
      existing.push({ name, help, type: 'histogram', value, labels });
    }
  }

  serialize(): string {
    const lines: string[] = [];
    const seen = new Set<string>();

    for (const entries of this.metrics.values()) {
      for (const entry of entries) {
        if (!seen.has(entry.name)) {
          lines.push(`# HELP ${entry.name} ${entry.help}`);
          lines.push(`# TYPE ${entry.name} ${entry.type}`);
          seen.add(entry.name);
        }
        const labelStr = entry.labels
          ? `{${Object.entries(entry.labels).map(([k, v]) => `${k}="${v}"`).join(',')}}`
          : '';
        lines.push(`${entry.name}${labelStr} ${entry.value}`);
      }
    }
    return lines.join('\n') + '\n';
  }

  private key(name: string, labels?: Record<string, string>): string {
    return labels ? `${name}:${JSON.stringify(labels)}` : name;
  }
}

export const registry = new MetricsRegistry();

export function startMetricsServer(port: number = 9100): http.Server {
  const server = http.createServer((_req, res) => {
    if (_req.url === '/metrics') {
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(registry.serialize());
    } else {
      res.writeHead(404);
      res.end('Not Found');
    }
  });

  server.listen(port, () => {
    console.log(`Metrics server listening on port ${port}`);
  });

  return server;
}
