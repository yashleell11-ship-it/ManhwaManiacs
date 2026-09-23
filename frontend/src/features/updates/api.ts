import { http } from "@/services/http";
import type { MarkAllReadRequest } from "./mark-all";
import type { UpdateNotification, UpdateRun, UpdateSettings } from "./types";

export const updatesApi = {
  // --- settings (GET / PUT, not PATCH) ---
  settings: () => http.get<UpdateSettings>("/updates/settings"),

  updateSettings: (body: Partial<UpdateSettings>) =>
    http.put<UpdateSettings>("/updates/settings", body),

  // --- notifications ---
  notifications: (params?: { unread_only?: boolean; limit?: number }) =>
    http.get<UpdateNotification[]>("/updates/notifications", { query: params }),

  unreadCount: () =>
    http.get<{ count: number }>("/updates/notifications/unread-count"),

  markRead: (notificationId: number) =>
    http.patch<UpdateNotification>(
      `/updates/notifications/${notificationId}/read`,
    ),

  // `content_kind` limits it to one content mode; omitted, every mode.
  markAllRead: (body?: MarkAllReadRequest) =>
    http.post<{ updated: number }>("/updates/notifications/read-all", body),

  // --- runs & manual checks ---
  runs: (limit?: number) =>
    http.get<UpdateRun[]>("/updates/runs", {
      query: limit ? { limit } : undefined,
    }),

  check: (body?: { followed_ids?: number[] }) =>
    http.post<UpdateRun | { queued: boolean }>("/updates/check", body ?? {}),

  checkFollowed: (followedId: number) =>
    http.post<UpdateRun>(`/updates/followed/${followedId}/check`),
};
