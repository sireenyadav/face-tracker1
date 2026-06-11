import './globals.css';

export const metadata = {
  title: 'Observer Dashboard — JEE Focus Monitor',
  description: 'Real-time focus telemetry for Sireen Yadav, JEE Mains 2027. Monitor study sessions, focus scores, and live verification.',
  keywords: 'JEE focus tracker, study monitor, parent dashboard, telemetry',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
