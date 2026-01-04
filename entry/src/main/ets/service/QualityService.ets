/**
 * 音质替换服务
 * 负责获取指定音质的音乐 URL
 */
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { NeteaseEncrypt, EncryptedParams } from '../utils/NeteaseEncrypt';

// 网易云音乐 API 基础 URL
const NETEASE_BASE_URL = 'https://music.163.com';
const SONG_URL_API_PATH = '/weapi/song/enhance/player/url/v1';

/**
 * 音质 URL 响应数据
 */
export interface QualityUrlData {
  id: number;
  url: string;
  level: string;
  size: number;
  type: string;
}

/**
 * API 响应中的数据项
 */
interface SongUrlDataItem {
  id?: number;
  url?: string;
  level?: string;
  size?: number;
  type?: string;
}

/**
 * 网易云音乐歌曲 URL API 响应
 */
interface SongUrlApiResponse {
  code: number;
  data?: SongUrlDataItem[];
}

/**
 * 歌曲 URL 请求参数
 */
interface SongUrlRequestData {
  ids: string;
  level: string;
  encodeType: string;
}

/**
 * 音质替换服务类
 */
export class QualityService {
  private static instance: QualityService | null = null;

  private constructor() {}

  /**
   * 获取单例实例
   */
  public static getInstance(): QualityService {
    if (!QualityService.instance) {
      QualityService.instance = new QualityService();
    }
    return QualityService.instance;
  }

  /**
   * 从 Cookie 字符串中提取 csrf_token
   */
  private extractCsrfToken(cookieStr: string): string {
    if (!cookieStr) return '';
    const cookies = cookieStr.split(';');
    for (const cookie of cookies) {
      const parts = cookie.trim().split('=');
      const name = parts[0];
      const value = parts.length > 1 ? parts[1] : '';
      if (name === '__csrf') {
        return value || '';
      }
    }
    return '';
  }

  /**
   * 获取 Cookie（从 WebCookieManager）
   */
  private async getCookies(): Promise<string> {
    try {
      const cookies = await webview.WebCookieManager.fetchCookie(NETEASE_BASE_URL);
      return cookies || '';
    } catch (error) {
      console.error('[QualityService] Failed to get cookies:', error);
      return '';
    }
  }

  /**
   * 获取指定音质的歌曲 URL
   * @param songId 歌曲 ID
   * @param level 音质等级 (standard, higher, exhigh, lossless, hires)
   */
  public async fetchQualityUrl(songId: number, level: string): Promise<QualityUrlData | null> {
    if (songId <= 0) {
      console.error('[QualityService] Invalid song ID');
      return null;
    }

    console.info(`[QualityService] Fetching quality URL for song ${songId}, level: ${level}`);

    try {
      // 获取 Cookie 和 csrf_token
      const cookies = await this.getCookies();
      const csrfToken = this.extractCsrfToken(cookies);

      // 构造请求参数
      const requestData: SongUrlRequestData = {
        ids: `[${songId}]`,
        level: level,
        encodeType: 'flac'
      };

      // 加密参数
      const encryptedParams: EncryptedParams = await NeteaseEncrypt.encrypt(requestData);

      // 构造请求 URL
      const url = `${NETEASE_BASE_URL}${SONG_URL_API_PATH}?csrf_token=${csrfToken}`;

      // 发送请求
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Cookie': cookies,
          'Referer': 'https://music.163.com/',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        },
        extraData: `params=${encodeURIComponent(encryptedParams.params)}&encSecKey=${encodeURIComponent(encryptedParams.encSecKey)}`
      });

      httpRequest.destroy();

      if (response.responseCode !== 200) {
        console.error(`[QualityService] HTTP error: ${response.responseCode}`);
        return null;
      }

      // 解析响应
      const responseData = JSON.parse(response.result as string) as SongUrlApiResponse;

      if (responseData.code !== 200 || !responseData.data || responseData.data.length === 0) {
        console.error(`[QualityService] API error: ${responseData.code}`);
        return null;
      }

      const data = responseData.data[0];
      if (!data.url) {
        console.warn(`[QualityService] No URL returned for song ${songId}, level: ${level}`);
        return null;
      }

      const result: QualityUrlData = {
        id: data.id || songId,
        url: data.url,
        level: data.level || level,
        size: data.size || 0,
        type: data.type || ''
      };

      console.info(`[QualityService] Got quality URL for song ${songId}: ${result.level}, size: ${result.size}`);
      return result;

    } catch (error) {
      console.error(`[QualityService] Failed to fetch quality URL:`, error);
      return null;
    }
  }
}

