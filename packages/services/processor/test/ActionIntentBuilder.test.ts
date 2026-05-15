import { describe, it } from 'node:test';

describe('ActionIntentBuilder', () => {
  it('should build a valid ActionIntent from a classified dividend event', () => {
    // TODO: Provide classified event, verify intent fields
  });

  it('should compute correct ABI-encoded params for split actions', () => {
    // TODO: Verify encoded params match expected split ratio encoding
  });

  it.todo('should reject events with missing required fields');

  it.todo('should set correct record date and ex-date from source data');
});
