const { greet } = require('../src/index');

test('greets a user', () => {
  expect(greet('World')).toBe('Hello, World!');
});
