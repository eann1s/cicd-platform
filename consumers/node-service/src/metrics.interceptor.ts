import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import { InjectMetric } from '@willsoto/nestjs-prometheus';
import { Counter, Histogram } from 'prom-client';
import { catchError, finalize, Observable, throwError } from 'rxjs';

type HttpLabels = 'method' | 'route' | 'status_class';

@Injectable()
export class MetricsInterceptor implements NestInterceptor {
  constructor(
    @InjectMetric('http_requests_total')
    private readonly requestsTotal: Counter<HttpLabels>,
    @InjectMetric('http_request_duration_seconds')
    private readonly requestDuration: Histogram<HttpLabels>,
  ) {}

  intercept(
    context: ExecutionContext,
    next: CallHandler<any>,
  ): Observable<any> | Promise<Observable<any>> {
    if (context.getType() != 'http') {
      return next.handle();
    }

    const http = context.switchToHttp();
    const req = http.getRequest();
    const res = http.getResponse();

    const method = req.method;

    const route =
      req.route?.path ?? req.routerPath ?? req.url?.split('?')[0] ?? 'unknown';

    if (route === '/metrics' || route === 'metrics') {
      return next.handle();
    }

    const start = process.hrtime.bigint();

    let errorStatusCode: number | undefined;

    return next.handle().pipe(
      catchError((err) => {
        errorStatusCode = err?.status ?? err.statusCode ?? 500;
        return throwError(() => err);
      }),
      finalize(() => {
        const durSeconds =
          Number(process.hrtime.bigint() - start) / 1_000_000_000;
        const statusClass = getStatusClass(
          errorStatusCode ?? res.statusCode ?? 500,
        );
        const labels = {
          method,
          route,
          status_class: statusClass,
        };

        this.requestsTotal.inc(labels);
        this.requestDuration.observe(labels, durSeconds);
      }),
    );
  }
}

function getStatusClass(status: number): string {
  if (status < 200) {
    return '1xx';
  } else if (status >= 200 && status < 300) {
    return '2xx';
  } else if (status >= 300 && status < 400) {
    return '3xx';
  } else if (status >= 400 && status < 500) {
    return '4xx';
  } else {
    return '5xx';
  }
}
