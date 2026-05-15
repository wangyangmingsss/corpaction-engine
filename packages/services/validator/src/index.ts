import { ValidatorNode } from './ValidatorNode';

async function main() {
  const node = new ValidatorNode(
    process.env.RPC_URL || 'http://localhost:8545',
    process.env.VALIDATOR_PRIVATE_KEY || '',
    process.env.REGISTRY_ADDRESS || '',
    process.env.REDIS_URL || 'redis://localhost:6379'
  );

  process.on('SIGTERM', async () => {
    console.log('Shutting down validator node...');
    await node.stop();
    process.exit(0);
  });

  await node.start();
}

main().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});
