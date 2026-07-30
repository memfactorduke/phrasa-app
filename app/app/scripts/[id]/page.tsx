import { EditorView } from "@/components/app/editor-view";

export default async function ScriptEditorPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return <EditorView scriptId={id} />;
}
