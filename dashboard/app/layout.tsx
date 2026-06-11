import './globals.css';

export const metadata = {
  title: 'Observer Dashboard',
  description: 'Continuous Probabilistic Fusion Telemetry',
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
