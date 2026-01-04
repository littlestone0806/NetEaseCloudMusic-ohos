/**
 * 轮询检查一个函数，直到它返回 true
 * @param checkFunction - 返回布尔值的检查函数
 * @param interval - 检查间隔（毫秒），默认 100ms
 * @param timeout - 超时时间（毫秒），0 表示永不超时，默认 10000ms
 * @returns 一个 Promise，在条件满足时 resolve，超时时 reject
 */
export function waitForCondition(checkFunction: () => boolean, interval: number = 100, timeout: number = 10000): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    const startTime = Date.now();

    const checkCondition = () => {
      // 1. 检查条件是否满足
      if (checkFunction()) {
        resolve();
        return;
      }

      // 2. 检查是否超时
      if (timeout > 0 && Date.now() - startTime >= timeout) {
        reject(new Error(`条件在 ${timeout} 毫秒后仍未满足`));
        return;
      }

      // 3. 如果不满足且未超时，则设定一个定时器，稍后再次检查
      setTimeout(checkCondition, interval);
    };

    // 立即开始第一次检查
    checkCondition();
  });
}

