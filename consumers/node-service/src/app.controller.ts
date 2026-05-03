import { Controller, Get, Res } from '@nestjs/common';
import { AppService } from './app.service';
import { Response } from 'express';

@Controller()
export class AppController {
  constructor(private readonly appService: AppService) {}

  @Get()
  getHello(): string {
    return this.appService.getHello();
  }

  @Get('healthz')
  getHealth(@Res() res: Response) {
    res.status(200).json({ status: 'ok' });
  }

  @Get('readyz')
  getReady(@Res() res: Response) {
    res.status(200).json({ status: 'ok' });
  }
}
