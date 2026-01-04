/**
 * 网易云音乐 API 请求参数加密工具类
 * 实现 weapi 接口的加密算法
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';
import { util } from '@kit.ArkTS';

// 网易云音乐加密常量
const MODULUS = '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7';
const NONCE = '0CoJUm6Qyw8W8jud';
const PUB_KEY = '010001';
const IV = '0102030405060708';

/**
 * 加密结果接口
 */
export interface EncryptedParams {
  params: string;
  encSecKey: string;
}

/**
 * 网易云音乐加密工具类
 */
export class NeteaseEncrypt {
  /**
   * 生成随机字符串
   * @param length 字符串长度
   * @returns 随机字符串
   */
  private static generateRandomString(length: number): string {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let result = '';
    for (let i = 0; i < length; i++) {
      const randomIndex = Math.floor(Math.random() * chars.length);
      result += chars.charAt(randomIndex);
    }
    return result;
  }

  /**
   * AES-128-CBC 加密
   * @param text 明文
   * @param key 密钥（16字节）
   * @returns Base64 编码的密文
   */
  private static async aesEncrypt(text: string, key: string): Promise<string> {
    try {
      // 将 key 和 iv 转换为 Uint8Array
      const keyData = new Uint8Array(buffer.from(key, 'utf-8').buffer);
      const ivData = new Uint8Array(buffer.from(IV, 'utf-8').buffer);
      const plainData = new Uint8Array(buffer.from(text, 'utf-8').buffer);

      // 创建对称密钥
      const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
      const symKeyBlob: cryptoFramework.DataBlob = { data: keyData };
      const symKey = await symKeyGenerator.convertKey(symKeyBlob);

      // 创建 IV 参数
      const ivParamsSpec: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: { data: ivData }
      };

      // 创建 Cipher 并加密
      const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivParamsSpec);
      const cipherData = await cipher.doFinal({ data: plainData });

      // 返回 Base64 编码的密文
      const base64Helper = new util.Base64Helper();
      return base64Helper.encodeToStringSync(cipherData.data);
    } catch (error) {
      console.error('[NeteaseEncrypt] AES encrypt error:', error);
      if (error instanceof Error) {
        throw error;
      }
      throw new Error(`AES encrypt error: ${String(error)}`);
    }
  }

  /**
   * 字符串反转
   */
  private static reverseString(str: string): string {
    return str.split('').reverse().join('');
  }

  /**
   * 将十六进制字符串转换为 BigInt 数组表示
   * 使用 16 位为一个 digit
   */
  private static hexToBigIntArray(hex: string): number[] {
    const digits: number[] = [];
    for (let i = hex.length; i > 0; i -= 4) {
      const start = Math.max(i - 4, 0);
      const chunk = hex.substring(start, i);
      digits.push(parseInt(chunk, 16) || 0);
    }
    // 确保数组足够大
    while (digits.length < 131) {
      digits.push(0);
    }
    return digits;
  }

  /**
   * BigInt 数组转换为十六进制字符串
   */
  private static bigIntArrayToHex(digits: number[]): string {
    let result = '';
    let started = false;
    for (let i = digits.length - 1; i >= 0; i--) {
      if (digits[i] !== 0 || started) {
        started = true;
        const hex = digits[i].toString(16);
        if (result.length > 0) {
          result += hex.padStart(4, '0');
        } else {
          result += hex;
        }
      }
    }
    return result || '0';
  }

  /**
   * BigInt 数组乘法
   */
  private static bigIntMultiply(a: number[], b: number[]): number[] {
    const result: number[] = new Array(262).fill(0);
    const aLen = NeteaseEncrypt.getHighIndex(a);
    const bLen = NeteaseEncrypt.getHighIndex(b);

    for (let i = 0; i <= bLen; i++) {
      let carry = 0;
      for (let j = 0; j <= aLen; j++) {
        const product = result[i + j] + a[j] * b[i] + carry;
        result[i + j] = product & 0xFFFF;
        carry = product >>> 16;
      }
      result[i + aLen + 1] = carry;
    }
    return result;
  }

  /**
   * 获取最高有效位索引
   */
  private static getHighIndex(digits: number[]): number {
    for (let i = digits.length - 1; i >= 0; i--) {
      if (digits[i] !== 0) return i;
    }
    return 0;
  }

  /**
   * 获取 BigInt 数组的位数
   */
  private static getNumBits(digits: number[]): number {
    const highIndex = NeteaseEncrypt.getHighIndex(digits);
    let digit = digits[highIndex];
    let bits = (highIndex + 1) * 16;
    for (let i = 0; i < 16 && (digit & 0x8000) === 0; i++) {
      bits--;
      digit <<= 1;
    }
    return bits;
  }

  /**
   * BigInt 数组左移
   */
  private static bigIntShiftLeft(a: number[], bits: number): number[] {
    const digitShift = Math.floor(bits / 16);
    const bitShift = bits % 16;
    const result: number[] = new Array(a.length + digitShift + 1).fill(0);

    for (let i = 0; i < a.length; i++) {
      result[i + digitShift] |= (a[i] << bitShift) & 0xFFFF;
      if (bitShift > 0 && i + digitShift + 1 < result.length) {
        result[i + digitShift + 1] |= a[i] >>> (16 - bitShift);
      }
    }
    return result;
  }

  /**
   * BigInt 数组右移
   */
  private static bigIntShiftRight(a: number[], bits: number): number[] {
    const digitShift = Math.floor(bits / 16);
    const bitShift = bits % 16;
    const result: number[] = new Array(a.length).fill(0);

    for (let i = digitShift; i < a.length; i++) {
      result[i - digitShift] = (a[i] >>> bitShift) & 0xFFFF;
      if (bitShift > 0 && i + 1 < a.length) {
        result[i - digitShift] |= (a[i + 1] << (16 - bitShift)) & 0xFFFF;
      }
    }
    return result;
  }

  /**
   * BigInt 数组比较
   */
  private static bigIntCompare(a: number[], b: number[]): number {
    const aHigh = NeteaseEncrypt.getHighIndex(a);
    const bHigh = NeteaseEncrypt.getHighIndex(b);

    if (aHigh !== bHigh) {
      return aHigh > bHigh ? 1 : -1;
    }

    for (let i = aHigh; i >= 0; i--) {
      if (a[i] !== b[i]) {
        return a[i] > b[i] ? 1 : -1;
      }
    }
    return 0;
  }

  /**
   * BigInt 数组减法
   */
  private static bigIntSubtract(a: number[], b: number[]): number[] {
    const result: number[] = new Array(Math.max(a.length, b.length)).fill(0);
    let borrow = 0;

    for (let i = 0; i < result.length; i++) {
      const aVal = i < a.length ? a[i] : 0;
      const bVal = i < b.length ? b[i] : 0;
      let diff = aVal - bVal - borrow;

      if (diff < 0) {
        diff += 0x10000;
        borrow = 1;
      } else {
        borrow = 0;
      }
      result[i] = diff;
    }
    return result;
  }

  /**
   * BigInt 数组取模
   */
  private static bigIntMod(a: number[], m: number[]): number[] {
    let result = a.slice();

    while (NeteaseEncrypt.bigIntCompare(result, m) >= 0) {
      const resultBits = NeteaseEncrypt.getNumBits(result);
      const mBits = NeteaseEncrypt.getNumBits(m);
      const shift = resultBits - mBits;

      let shifted = NeteaseEncrypt.bigIntShiftLeft(m, shift);
      if (NeteaseEncrypt.bigIntCompare(result, shifted) < 0) {
        shifted = NeteaseEncrypt.bigIntShiftLeft(m, shift - 1);
      }
      result = NeteaseEncrypt.bigIntSubtract(result, shifted);
    }
    return result;
  }

  /**
   * 模幂运算 (base^exp mod mod)
   */
  private static modPow(base: number[], exp: number[], mod: number[]): number[] {
    let result: number[] = new Array(131).fill(0);
    result[0] = 1;

    let b = base.slice();
    let e = exp.slice();

    while (NeteaseEncrypt.getHighIndex(e) > 0 || e[0] !== 0) {
      if ((e[0] & 1) === 1) {
        result = NeteaseEncrypt.bigIntMod(NeteaseEncrypt.bigIntMultiply(result, b), mod);
      }
      e = NeteaseEncrypt.bigIntShiftRight(e, 1);
      if (NeteaseEncrypt.getHighIndex(e) > 0 || e[0] !== 0) {
        b = NeteaseEncrypt.bigIntMod(NeteaseEncrypt.bigIntMultiply(b, b), mod);
      }
    }
    return result;
  }

  /**
   * RSA 加密（使用自定义大数运算）
   * @param text 明文
   * @returns 十六进制密文
   */
  private static rsaEncrypt(text: string): string {
    // 将文本反转并转换为十六进制
    const reversedText = NeteaseEncrypt.reverseString(text);
    let hexText = '';
    for (let i = 0; i < reversedText.length; i++) {
      hexText += reversedText.charCodeAt(i).toString(16).padStart(2, '0');
    }

    // 转换为 BigInt 数组
    const textBigInt = NeteaseEncrypt.hexToBigIntArray(hexText);
    const expBigInt = NeteaseEncrypt.hexToBigIntArray(PUB_KEY);
    const modBigInt = NeteaseEncrypt.hexToBigIntArray(MODULUS);

    // 执行模幂运算
    const result = NeteaseEncrypt.modPow(textBigInt, expBigInt, modBigInt);

    // 转换为十六进制字符串，确保长度为 256
    let hexResult = NeteaseEncrypt.bigIntArrayToHex(result);
    while (hexResult.length < 256) {
      hexResult = '0' + hexResult;
    }
    return hexResult;
  }

  /**
   * 加密请求参数（主入口）
   * @param data 要加密的数据对象
   * @returns 加密后的参数
   */
  public static async encrypt(data: object): Promise<EncryptedParams> {
    try {
      const text = JSON.stringify(data);

      // 生成 16 位随机密钥
      const secretKey = NeteaseEncrypt.generateRandomString(16);

      // 第一次 AES 加密：使用固定密钥 NONCE
      const firstEncrypt = await NeteaseEncrypt.aesEncrypt(text, NONCE);

      // 第二次 AES 加密：使用随机密钥
      const params = await NeteaseEncrypt.aesEncrypt(firstEncrypt, secretKey);

      // RSA 加密随机密钥
      const encSecKey = NeteaseEncrypt.rsaEncrypt(secretKey);

      return {
        params: params,
        encSecKey: encSecKey
      };
    } catch (error) {
      console.error('[NeteaseEncrypt] Encrypt error:', error);
      if (error instanceof Error) {
        throw error;
      }
      throw new Error(`Encrypt error: ${String(error)}`);
    }
  }

  /**
   * 同步版本的加密方法
   * @param data 要加密的数据对象
   * @returns 加密后的参数
   */
  public static encryptSync(data: object): EncryptedParams {
    try {
      const text = JSON.stringify(data);

      // 生成 16 位随机密钥
      const secretKey = NeteaseEncrypt.generateRandomString(16);

      // 使用同步方式进行 AES 加密
      const firstEncrypt = NeteaseEncrypt.aesEncryptSync(text, NONCE);
      const params = NeteaseEncrypt.aesEncryptSync(firstEncrypt, secretKey);

      // RSA 加密随机密钥
      const encSecKey = NeteaseEncrypt.rsaEncrypt(secretKey);

      return {
        params: params,
        encSecKey: encSecKey
      };
    } catch (error) {
      console.error('[NeteaseEncrypt] EncryptSync error:', error);
      if (error instanceof Error) {
        throw error;
      }
      throw new Error(`EncryptSync error: ${String(error)}`);
    }
  }

  /**
   * 同步 AES-128-CBC 加密
   */
  private static aesEncryptSync(text: string, key: string): string {
    try {
      const keyData = new Uint8Array(buffer.from(key, 'utf-8').buffer);
      const ivData = new Uint8Array(buffer.from(IV, 'utf-8').buffer);
      const plainData = new Uint8Array(buffer.from(text, 'utf-8').buffer);

      const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
      const symKeyBlob: cryptoFramework.DataBlob = { data: keyData };
      const symKey = symKeyGenerator.convertKeySync(symKeyBlob);

      const ivParamsSpec: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: { data: ivData }
      };

      const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivParamsSpec);
      const cipherData = cipher.doFinalSync({ data: plainData });

      const base64Helper = new util.Base64Helper();
      return base64Helper.encodeToStringSync(cipherData.data);
    } catch (error) {
      console.error('[NeteaseEncrypt] AES encryptSync error:', error);
      if (error instanceof Error) {
        throw error;
      }
      throw new Error(`AES encryptSync error: ${String(error)}`);
    }
  }
}
