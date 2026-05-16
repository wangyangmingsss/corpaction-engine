import { randomUUID } from 'crypto';

export class Logger {
  private service: string;
  private component: string;
  private _traceId: string;

  constructor(service: string, component: string) {
    this.service = service;
    this.component = component;
    this._traceId = randomUUID();
  }

  /** Set a new trace ID for each request/event processing cycle */
  setTraceId(traceId?: string): void {
    this._traceId = traceId ?? randomUUID();
  }

  get traceId(): string {
    return this._traceId;
  }

  info(message: string, meta?: Record<string, unknown>): void {
    this.log('info', message, meta);
  }

  warn(message: string, meta?: Record<string, unknown>): void {
    this.log('warn', message, meta);
  }

  error(message: string, meta?: Record<string, unknown>): void {
    this.log('error', message, meta);
  }

  debug(message: string, meta?: Record<string, unknown>): void {
    this.log('debug', message, meta);
  }

  private log(level: string, message: string, meta?: Record<string, unknown>): void {
    const entry = {
      timestamp: new Date().toISOString(),
      level,
      service: this.service,
      component: this.component,
      trace_id: this._traceId,
      event: message,
      ...meta,
    };
    console.log(JSON.stringify(entry));
  }
}
