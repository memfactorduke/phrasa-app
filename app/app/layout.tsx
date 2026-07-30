import type { Metadata } from "next";
import { AppProvider } from "@/components/app/app-provider";

export const metadata: Metadata = {
  title: "Web app",
  description:
    "Phrasa web companion: local script library, editor, and speed teleprompter. Optional cloud sync when configured.",
  robots: {
    index: false,
    follow: true,
  },
};

export default function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return <AppProvider>{children}</AppProvider>;
}
