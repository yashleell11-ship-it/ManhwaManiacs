"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { ArrowLeft, BookOpen, Minus, Pencil, Plus, Search, Trash2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { EmptyState } from "@/components/ui/empty-state";
import { Input } from "@/components/ui/input";
import { libraryCoverUrl } from "@/features/library/api";
import { CONTENT_MODE_COPY, useContentModeFilter } from "@/features/content-mode";
import {
  type CollectionMember,
  collectionMemberKeys,
  collectionUpdateBody,
  resolveCollectionMembers,
  seriesRefKey,
} from "@/features/library/collections";
import {
  useAddSeriesToCollection,
  useAllFollowedSeries,
  useCollection,
  useDeleteCollection,
  useRemoveSeriesFromCollection,
  useUpdateCollection,
} from "@/features/library/hooks";
import { apiErrorMessage } from "@/lib/view-state";
import { cn } from "@/lib/cn";
import { SeriesGrid } from "./SeriesGrid";
import type { FollowedSeries } from "../types";
import { CoverImage } from "@/components/ui/cover-image";

interface CollectionDetailViewProps {
  collectionId: number;
}

/** The cover thumbnail in both membership dialogs — fixed, so no breakpoints. */
const ROW_COVER_SIZES = "32px";

function DetailSkeleton() {
  return (
    <div
      className="min-h-full bg-bg px-6 py-6 md:px-10"
      aria-busy="true"
      aria-label="Loading collection"
    >
      <div className="mx-auto max-w-7xl">
        <div className="mb-6 h-4 w-40 animate-pulse rounded bg-surface-2" />
        <div className="mb-8 h-48 animate-pulse rounded-2xl bg-surface-2" />
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
          {Array.from({ length: 6 }).map((_, index) => (
            <div key={index} className="aspect-[2/3] animate-pulse rounded-xl bg-surface-2" />
          ))}
        </div>
      </div>
    </div>
  );
}

export function CollectionDetailView({ collectionId }: CollectionDetailViewProps) {
  const collectionQuery = useCollection(collectionId);
  // Every follow, not the first page: members, the add picker and the remove
  // list are all joined against this, and a follow past the first 200 was
  // missing from the grid, never offered, and called "No longer followed".
  const allSeriesQuery = useAllFollowedSeries();
  // A collection is a shelf, not a medium: it can hold both, so the mode scopes
  // what is listed INSIDE it rather than which collections exist — the same
  // split `collection_detail_screen.dart` makes. A no-op when novels are off.
  const { filterRows, mode, novelsEnabled } = useContentModeFilter();
  const addSeries = useAddSeriesToCollection();
  const removeSeries = useRemoveSeriesFromCollection();
  const updateCollection = useUpdateCollection();
  const deleteCollection = useDeleteCollection();
  const [showAddDialog, setShowAddDialog] = useState(false);
  const [addSearch, setAddSearch] = useState("");
  const [showRemoveDialog, setShowRemoveDialog] = useState(false);
  // Which row has armed its confirm step. Inline rather than a second Dialog:
  // stacked dialogs both listen for Escape, so one press would close both.
  const [confirmRemoveKey, setConfirmRemoveKey] = useState<string | null>(null);
  const [showEditDialog, setShowEditDialog] = useState(false);
  const [editName, setEditName] = useState("");
  const [editDescription, setEditDescription] = useState("");
  const [showDeleteDialog, setShowDeleteDialog] = useState(false);

  const collection = collectionQuery.data;
  const allSeries = useMemo(
    () => allSeriesQuery.data ?? [],
    [allSeriesQuery.data],
  );

  // Collection membership is `(source_id, series_key)` refs; resolve them
  // against the followed set for cover + title.
  const memberKeys = useMemo(
    () => collectionMemberKeys(collection?.series ?? []),
    [collection],
  );

  const members = useMemo<FollowedSeries[]>(
    () =>
      filterRows(
        allSeries.filter((s) => memberKeys.has(seriesRefKey(s.source_id, s.series_key))),
        (s) => s.source_id,
      ),
    [allSeries, filterRows, memberKeys],
  );

  // The remove list runs off the refs, not `members`: a series that was
  // unfollowed after being added keeps its membership and would otherwise be
  // in the collection with no way out.
  const removableMembers = useMemo(
    () => resolveCollectionMembers(collection?.series ?? [], allSeries),
    [collection, allSeries],
  );

  if (collectionQuery.isLoading) {
    return <DetailSkeleton />;
  }

  if (collectionQuery.error || !collection) {
    return (
      <div className="flex min-h-[40vh] flex-col items-center justify-center gap-4 p-6 text-center">
        <p className="text-danger">
          {apiErrorMessage(collectionQuery.error, "Failed to load collection.")}
        </p>
        <Link href="/library/collections">
          <Button variant="secondary" className="gap-2">
            <ArrowLeft className="size-4" aria-hidden />
            Back to collections
          </Button>
        </Link>
      </div>
    );
  }

  // The picker offers what this mode can add, for the same reason the grid
  // shows what this mode holds: a Novels-mode shelf that lists manhwa to add is
  // the mixing the mode exists to stop.
  const availableSeries = filterRows(
    allSeries.filter(
      (series) => !memberKeys.has(seriesRefKey(series.source_id, series.series_key)),
    ),
    (series) => series.source_id,
  );
  const filteredAvailable = addSearch.trim()
    ? availableSeries.filter((series) =>
        series.title.toLowerCase().includes(addSearch.toLowerCase()),
      )
    : availableSeries;

  const editBody = collectionUpdateBody(collection, {
    name: editName,
    description: editDescription,
  });

  const openEdit = () => {
    updateCollection.reset();
    setEditName(collection.name);
    setEditDescription(collection.description ?? "");
    setShowEditDialog(true);
  };

  const handleSaveEdit = async () => {
    if (!editBody) return;
    try {
      await updateCollection.mutateAsync({ collectionId, body: editBody });
      setShowEditDialog(false);
    } catch {
      // Error surfaced via mutation state
    }
  };

  const handleRemove = (member: CollectionMember) => {
    removeSeries.mutate(
      {
        collectionId,
        ref: {
          sourceId: member.ref.source_id,
          seriesKey: member.ref.series_key,
        },
      },
      { onSuccess: () => setConfirmRemoveKey(null) },
    );
  };

  return (
    <div className="min-h-full bg-bg">
      <div className="relative overflow-hidden border-b border-border/50">
        <div className="absolute inset-0">
          <div className="h-full w-full bg-gradient-to-br from-accent/30 via-void to-primary/20" />
          <div className="absolute inset-0 bg-gradient-to-b from-void/40 via-void/80 to-bg" />
        </div>

        <div className="relative mx-auto max-w-7xl px-6 py-6 md:px-10">
          <Link
            href="/library/collections"
            className="mb-6 inline-flex items-center gap-1.5 text-sm text-muted transition-colors hover:text-primary"
          >
            <ArrowLeft className="size-3.5" aria-hidden />
            Back to collections
          </Link>

          <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <div className="min-w-0">
              <h1 className="font-display text-4xl tracking-wide text-fg">
                {collection.name}
              </h1>
              {collection.description && (
                <p className="mt-2 max-w-2xl text-sm text-muted">
                  {collection.description}
                </p>
              )}
              <p className="mt-3 inline-flex items-center gap-1.5 text-sm text-muted">
                <BookOpen className="size-4 text-primary" aria-hidden />
                {collection.series.length} series
              </p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Button variant="secondary" onClick={openEdit} className="gap-2">
                <Pencil className="size-4" aria-hidden />
                Edit
              </Button>
              <Button
                variant="secondary"
                onClick={() => setShowAddDialog(true)}
                className="gap-2"
              >
                <Plus className="size-4" aria-hidden />
                Add Series
              </Button>
              {collection.series.length > 0 && (
                <Button
                  variant="secondary"
                  onClick={() => {
                    removeSeries.reset();
                    setConfirmRemoveKey(null);
                    setShowRemoveDialog(true);
                  }}
                  className="gap-2"
                >
                  <Minus className="size-4" aria-hidden />
                  Remove Series
                </Button>
              )}
              <Button
                variant="danger"
                onClick={() => {
                  deleteCollection.reset();
                  setShowDeleteDialog(true);
                }}
                className="gap-2"
              >
                <Trash2 className="size-4" aria-hidden />
                Delete
              </Button>
            </div>
          </div>
        </div>
      </div>

      <div className="mx-auto max-w-7xl px-6 py-8 md:px-10">
        {collection.series.length === 0 ? (
          <EmptyState
            icon={BookOpen}
            title="This collection is empty"
            description="Add series from your library to start building this collection."
            action={{
              label: "Add series",
              icon: Plus,
              onClick: () => setShowAddDialog(true),
            }}
          />
        ) : novelsEnabled && members.length === 0 && !allSeriesQuery.isLoading ? (
          <EmptyState
            icon={BookOpen}
            title={`No ${CONTENT_MODE_COPY[mode].plural} in this collection`}
            description="It holds titles from the other mode. Switch modes to see them."
          />
        ) : (
          <SeriesGrid items={members} isLoading={allSeriesQuery.isLoading} />
        )}
      </div>

      <Dialog
        open={showEditDialog}
        onClose={() => setShowEditDialog(false)}
        title="Edit Collection"
        className="glass-panel max-w-md border-border/50"
      >
        <div className="space-y-4">
          <div>
            <label
              htmlFor="collection-edit-name"
              className="mb-1.5 block text-sm font-medium text-fg"
            >
              Name
            </label>
            <Input
              id="collection-edit-name"
              value={editName}
              onChange={(e) => setEditName(e.target.value)}
              placeholder="My Reading List"
              className="border-border/50 bg-white/[0.03]"
            />
          </div>
          <div>
            <label
              htmlFor="collection-edit-description"
              className="mb-1.5 block text-sm font-medium text-fg"
            >
              Description
            </label>
            <Input
              id="collection-edit-description"
              value={editDescription}
              onChange={(e) => setEditDescription(e.target.value)}
              placeholder="Optional description"
              className="border-border/50 bg-white/[0.03]"
            />
          </div>
          {updateCollection.error && (
            <p className="text-sm text-danger">
              {apiErrorMessage(updateCollection.error, "Failed to save changes.")}
            </p>
          )}
          <div className="flex justify-end gap-2 pt-2">
            <Button
              variant="secondary"
              onClick={() => setShowEditDialog(false)}
              disabled={updateCollection.isPending}
            >
              Cancel
            </Button>
            <Button
              onClick={handleSaveEdit}
              disabled={
                !editName.trim() || editBody === null || updateCollection.isPending
              }
              className="min-w-[100px]"
            >
              {updateCollection.isPending ? "Saving…" : "Save"}
            </Button>
          </div>
        </div>
      </Dialog>

      <Dialog
        open={showAddDialog}
        onClose={() => {
          setShowAddDialog(false);
          setAddSearch("");
        }}
        title="Add Series to Collection"
        className="glass-panel max-w-lg border-border/50"
      >
        <div className="space-y-4">
          <div className="relative">
            <Search
              className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted"
              aria-hidden
            />
            <Input
              value={addSearch}
              onChange={(e) => setAddSearch(e.target.value)}
              placeholder="Search series…"
              className="border-border/50 bg-white/[0.03] pl-10"
            />
          </div>
          <div className="max-h-[400px] space-y-2 overflow-y-auto pr-1">
            {allSeriesQuery.isLoading ? (
              <div className="space-y-2">
                {Array.from({ length: 4 }).map((_, index) => (
                  <div key={index} className="h-14 animate-pulse rounded-xl bg-surface-2" />
                ))}
              </div>
            ) : filteredAvailable.length === 0 ? (
              <p className="py-8 text-center text-sm text-muted">No series available.</p>
            ) : (
              filteredAvailable.map((series) => (
                <button
                  key={series.id}
                  type="button"
                  onClick={() => {
                    addSeries.mutate(
                      {
                        collectionId,
                        ref: {
                          sourceId: series.source_id,
                          seriesKey: series.series_key,
                        },
                      },
                      {
                        onSuccess: () => {
                          setShowAddDialog(false);
                          setAddSearch("");
                        },
                      },
                    );
                  }}
                  disabled={addSeries.isPending}
                  className={cn(
                    "flex w-full items-center gap-3 rounded-xl border border-border/50 bg-white/[0.02] px-3 py-2.5 text-left transition-all duration-200",
                    "hover:border-primary/30 hover:bg-primary/5",
                    addSeries.isPending && "opacity-60",
                  )}
                >
                  <div className="relative h-12 w-8 shrink-0 overflow-hidden rounded-lg bg-surface-2 ring-1 ring-white/10">
                    <CoverImage
                      src={libraryCoverUrl(series.cover_url, ROW_COVER_SIZES)}
                      alt={series.title}
                      fill
                      className="object-cover"
                      sizes={ROW_COVER_SIZES}
                      unoptimized
                    />
                  </div>
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-fg">{series.title}</p>
                  </div>
                </button>
              ))
            )}
          </div>
        </div>
      </Dialog>

      <Dialog
        open={showRemoveDialog}
        onClose={() => {
          setShowRemoveDialog(false);
          setConfirmRemoveKey(null);
        }}
        title="Remove Series from Collection"
        className="glass-panel max-w-lg border-border/50"
      >
        <div className="space-y-4">
          <p className="text-sm text-muted">
            Removing a series takes it out of this collection only — it stays in your
            library.
          </p>
          {removeSeries.error && (
            <p className="text-sm text-danger">
              {apiErrorMessage(removeSeries.error, "Failed to remove that series.")}
            </p>
          )}
          <div className="max-h-[400px] space-y-2 overflow-y-auto pr-1">
            {removableMembers.length === 0 ? (
              <p className="py-8 text-center text-sm text-muted">
                This collection is empty.
              </p>
            ) : (
              removableMembers.map((member) => (
                <div
                  key={member.key}
                  className="flex w-full items-center gap-3 rounded-xl border border-border/50 bg-white/[0.02] px-3 py-2.5"
                >
                  <div className="relative h-12 w-8 shrink-0 overflow-hidden rounded-lg bg-surface-2 ring-1 ring-white/10">
                    {member.series && (
                      <CoverImage
                        src={libraryCoverUrl(member.series.cover_url, ROW_COVER_SIZES)}
                        alt=""
                        fill
                        className="object-cover"
                        sizes={ROW_COVER_SIZES}
                        unoptimized
                      />
                    )}
                  </div>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium text-fg">{member.label}</p>
                    {!member.series && (
                      <p className="truncate text-xs text-muted">No longer followed</p>
                    )}
                  </div>
                  {confirmRemoveKey === member.key ? (
                    <div className="flex shrink-0 items-center gap-2">
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => setConfirmRemoveKey(null)}
                        disabled={removeSeries.isPending}
                      >
                        Cancel
                      </Button>
                      <Button
                        variant="danger"
                        size="sm"
                        onClick={() => handleRemove(member)}
                        disabled={removeSeries.isPending}
                      >
                        {removeSeries.isPending ? "Removing…" : "Remove"}
                      </Button>
                    </div>
                  ) : (
                    <Button
                      variant="ghost"
                      size="icon"
                      onClick={() => {
                        removeSeries.reset();
                        setConfirmRemoveKey(member.key);
                      }}
                      aria-label={`Remove ${member.label} from this collection`}
                      className="shrink-0 text-muted hover:text-danger"
                    >
                      <X className="size-4" aria-hidden />
                    </Button>
                  )}
                </div>
              ))
            )}
          </div>
        </div>
      </Dialog>

      <Dialog
        open={showDeleteDialog}
        onClose={() => setShowDeleteDialog(false)}
        title="Delete collection?"
        className="glass-panel max-w-md border-border/50"
      >
        <div className="space-y-4">
          <p className="text-sm text-fg/90">
            Delete <span className="font-medium">{collection.name}</span>? The series in
            it stay in your library. This cannot be undone.
          </p>
          {deleteCollection.error && (
            <p className="text-sm text-danger">
              {apiErrorMessage(deleteCollection.error, "Failed to delete this collection.")}
            </p>
          )}
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              onClick={() => setShowDeleteDialog(false)}
              disabled={deleteCollection.isPending}
            >
              Cancel
            </Button>
            <Button
              variant="danger"
              onClick={() =>
                deleteCollection.mutate(collectionId, {
                  onSuccess: () => setShowDeleteDialog(false),
                })
              }
              disabled={deleteCollection.isPending}
            >
              {deleteCollection.isPending ? "Deleting…" : "Delete"}
            </Button>
          </div>
        </div>
      </Dialog>
    </div>
  );
}
