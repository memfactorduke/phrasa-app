import { ReaderView } from "@/components/app/reader-view";

export default async function ScriptReaderPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return <ReaderView scriptId={id} />;
}
