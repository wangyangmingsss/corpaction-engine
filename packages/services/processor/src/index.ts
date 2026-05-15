import { ethers } from 'ethers';
import { Redis } from 'ioredis';

const logger = {
  info: (msg: string, meta?: Record<string, unknown>) =>
    console.log(JSON.stringify({ timestamp: new Date().toISOString(), level: 'info', service: 'processor', message: msg, ...meta })),
  error: (msg: string, meta?: Record<string, unknown>) =>
    console.log(JSON.stringify({ timestamp: new Date().toISOString(), level: 'error', service: 'processor', message: msg, ...meta })),
};

async function main() {
  const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');

  logger.info('Processor service starting');

  // Listen for classified events from Redis stream
  let lastId = '0';

  while (true) {
    try {
      const results = await redis.xread(
        'BLOCK', 5000,
        'COUNT', 10,
        'STREAMS', 'corpaction:classified_events', lastId
      );

      if (results) {
        for (const [, messages] of results) {
          for (const [id, fields] of messages) {
            lastId = id;
            const data = JSON.parse(fields[fields.indexOf('data') + 1]);
            logger.info('Processing classified event', {
              ticker: data.event?.ticker,
              actionType: data.classification?.actionType,
            });
          }
        }
      }
    } catch (error) {
      logger.error('Processing error', { error: String(error) });
      await new Promise(r => setTimeout(r, 5000));
    }
  }
}

main().catch((error) => {
  logger.error('Fatal error', { error: String(error) });
  process.exit(1);
});
