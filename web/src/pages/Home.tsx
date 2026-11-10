import { useTranslation } from 'react-i18next';

export function Home() {
  const { t } = useTranslation();
  return (
    <div className="page-container">
      <h1>{t('home.heading.title','Welcome!')}</h1>
      <p>
        {t('home.paragraph.description',
          'This is the start page of the Kairos Template for your application.')}
      </p>
    </div>
  );
}
