export class Logger {
  private service: string;
  private component: string;

  constructor(service: string, component: string) {
    this.service = service;
    this.component = component;
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
      message,
      ...meta,
    };
    console.log(JSON.stringify(entry));
  }
}
