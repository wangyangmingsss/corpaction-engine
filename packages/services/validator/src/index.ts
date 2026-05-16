import { ValidatorNode } from './ValidatorNode';
import { SourceVerifier } from './SourceVerifier';
import { Logger } from './utils/Logger';
import { startMetricsServer } from './metrics';

const logger = new Logger('validator', 'main');

startMetricsServer();

async function main() {
  const sourceVerifier = new SourceVerifier();

  const node = new ValidatorNode(
    process.env.RPC_URL || 'http://localhost:8545',
    process.env.VALIDATOR_PRIVATE_KEY || '',
    process.env.REGISTRY_ADDRESS || '',
    process.env.REDIS_URL || 'redis://localhost:6379',
    [sourceVerifier]
  );

  process.on('SIGTERM', async () => {
    logger.info('Shutting down validator node...');
    await node.stop();
    process.exit(0);
  });

  await node.start();
}

main().catch((error) => {
  logger.error('Fatal error', { error: String(error) });
  process.exit(1);
});
