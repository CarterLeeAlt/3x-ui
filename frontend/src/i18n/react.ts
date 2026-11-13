import i18next from 'i18next';
import { initReactI18next } from 'react-i18next';
import dayjs from 'dayjs';
import 'dayjs/locale/zh-cn';

import zhCN from '../../../web/translation/zh-CN.json';

const LANGUAGE = 'zh-CN';
dayjs.locale('zh-cn');

export async function readyI18n() {
  await i18next.use(initReactI18next).init({
    lng: LANGUAGE,
    fallbackLng: LANGUAGE,
    resources: { [LANGUAGE]: { translation: zhCN } },
    interpolation: { escapeValue: false, prefix: '{', suffix: '}' },
    returnNull: false,
  });
  return i18next;
}

export { i18next as i18n };
