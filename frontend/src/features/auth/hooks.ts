import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ApiError } from "@/types/api";
// Direct, not via the profiles barrel, which pulls in the picker components.
import { useActiveProfileStore } from "@/features/profiles/store";
import { isUnauthorizedError } from "./access";
import { authApi } from "./api";
import type {
  AccountSession,
  ChangePasswordPayload,
  LoginPayload,
  RegisterPayload,
  User,
} from "./types";

export const AUTH_KEY = ["auth"] as const;
/** The single source of truth for "who is signed in" — read by the guard, menu, and sidebar. */
export const CURRENT_USER_QUERY_KEY = [...AUTH_KEY, "me"] as const;
export const BOOTSTRAP_QUERY_KEY = [...AUTH_KEY, "bootstrap"] as const;
/** This account's live sessions. Account-level, so it survives a profile switch. */
export const SESSIONS_QUERY_KEY = [...AUTH_KEY, "sessions"] as const;

/**
 * Tell the profile store who is signed in, BEFORE the user reaches the cache.
 *
 * The shell renders the app the moment the current user is known, and every
 * request from then on carries the remembered profile as `X-Profile-Id`. The
 * store has to have dropped another account's selection by then, not an effect
 * later, or the first screen's reads go out under that account's profile.
 */
function bindSignedInUser(user: User | null): void {
  useActiveProfileStore.getState().bindSessionUser(user?.id ?? null);
}

/**
 * Forget the profile chosen in this session on the way out, so the next
 * account on this browser starts at the picker — and so the boot script,
 * which tints the page from the stored selection before React loads, stops
 * wearing this profile's mood.
 */
function forgetSignedInUser(): void {
  const store = useActiveProfileStore.getState();
  store.clearActiveProfile();
  store.bindSessionUser(null);
}

/**
 * The current signed-in user, or `null` when not authenticated. A 401 from
 * `/auth/me` is the normal "not signed in" outcome, so it resolves to `null`
 * rather than throwing; we never retry the probe.
 */
export function useCurrentUser() {
  return useQuery<User | null>({
    queryKey: CURRENT_USER_QUERY_KEY,
    queryFn: async () => {
      try {
        const user = await authApi.me();
        bindSignedInUser(user);
        return user;
      } catch (error) {
        if (error instanceof ApiError && error.status === 401) return null;
        throw error;
      }
    },
    retry: false,
    staleTime: 5 * 60_000,
  });
}

/** Public bootstrap/registration gate used by the login and register screens. */
export function useBootstrapStatus() {
  return useQuery({
    queryKey: BOOTSTRAP_QUERY_KEY,
    queryFn: () => authApi.bootstrapStatus(),
    retry: false,
    staleTime: 60_000,
  });
}

export function useLogin() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (payload: LoginPayload) => authApi.login(payload),
    onSuccess: (data) => {
      bindSignedInUser(data.user);
      // Seed the current-user cache directly so the guard admits the app
      // immediately, without a redundant /auth/me round-trip.
      queryClient.setQueryData(CURRENT_USER_QUERY_KEY, data.user);
    },
  });
}

export function useRegister() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (payload: RegisterPayload) => authApi.register(payload),
    onSuccess: (data) => {
      bindSignedInUser(data.user);
      queryClient.setQueryData(CURRENT_USER_QUERY_KEY, data.user);
      // Creating the first account flips `needs_bootstrap`; keep the gate fresh.
      void queryClient.invalidateQueries({ queryKey: BOOTSTRAP_QUERY_KEY });
    },
  });
}

/**
 * The account's live sessions. Never cached across a mount: `current` is
 * computed against the caller's own token and a revoked row must disappear the
 * moment it is revoked, so a stale list here is a list that lies about who is
 * signed in.
 */
export function useSessions() {
  const queryClient = useQueryClient();
  return useQuery<AccountSession[]>({
    queryKey: SESSIONS_QUERY_KEY,
    queryFn: async () => {
      try {
        return await authApi.sessions();
      } catch (error) {
        // The global 401 handler skips the whole `auth` namespace (it would
        // loop on /auth/me), so an expired session has to be reported from
        // here — otherwise the panel shows an error the guard never acts on
        // and the user sits in an app they are no longer signed in to.
        if (isUnauthorizedError(error)) {
          queryClient.setQueryData(CURRENT_USER_QUERY_KEY, null);
        }
        throw error;
      }
    },
    retry: false,
    staleTime: 0,
  });
}

/**
 * Rotate the password. The server revokes every OTHER session on success and
 * keeps this one, so the cached list is refetched rather than assumed.
 *
 * The payload is passed straight through and never cached: react-query holds
 * `variables` for the lifetime of the mutation observer, which is why callers
 * must not park form values in it beyond the call.
 */
export function useChangePassword() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (payload: ChangePasswordPayload) => authApi.changePassword(payload),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: SESSIONS_QUERY_KEY });
    },
  });
}

/** Revoke one other session. Never called for the current one — see `sessionRowAction`. */
export function useRevokeSession() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (sessionId: number) => authApi.revokeSession(sessionId),
    onSettled: () => {
      // Also on failure: a 404 means the row is already gone, and the list
      // should stop offering to revoke it either way.
      void queryClient.invalidateQueries({ queryKey: SESSIONS_QUERY_KEY });
    },
  });
}

export function useLogout() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => authApi.logout(),
    // Runs on success and error: even if the cookie was already invalid we
    // still drop every cached query (so the next user starts clean) and mark
    // the session as signed out.
    onSettled: () => {
      forgetSignedInUser();
      queryClient.removeQueries();
      queryClient.setQueryData(CURRENT_USER_QUERY_KEY, null);
    },
  });
}

/**
 * Sign out everywhere: revokes every session for the account, this one
 * included, and clears the cookie.
 *
 * Unlike `useLogout`, this clears local state on SUCCESS only. Clearing it on
 * failure too made a refused revocation indistinguishable from a completed
 * one: nulling the cached user trips the shell's route guard
 * (`resolveSessionGate` answers "redirect" the moment `/auth/me` data is null),
 * so the caller was bounced to /login before the panel's error could be read —
 * while every session the server never revoked stayed alive. This is the
 * control a user reaches for when they think someone else has their password,
 * so a silent failure is the one outcome it must not have. A `logout-all` that
 * failed because the session was already dead still resolves itself: the next
 * `/auth/me` answers 401, which `useCurrentUser` reports as null.
 */
export function useLogoutAll() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => authApi.logoutAll(),
    onSuccess: () => {
      forgetSignedInUser();
      queryClient.removeQueries();
      queryClient.setQueryData(CURRENT_USER_QUERY_KEY, null);
    },
  });
}
