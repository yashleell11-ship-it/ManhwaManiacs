import { QueryClient } from "@tanstack/react-query";
import { beforeEach, describe, expect, it } from "vitest";
import { useActiveProfileStore } from "@/features/profiles/store";
import type { Profile } from "@/features/profiles/types";
import { adoptSignedInUser, BOOTSTRAP_QUERY_KEY, CURRENT_USER_QUERY_KEY } from "./hooks";
import type { User } from "./types";

function user(id: number): User {
  return {
    id,
    username: `user${id}`,
    email: null,
    display_name: null,
    is_admin: false,
    created_at: "2026-09-01T00:00:00Z",
    last_login_at: null,
  };
}

const PROFILE_OF_A: Profile = {
  id: 10,
  name: "A's profile",
  avatar_key: null,
  mood: "action",
  sort_order: 0,
  mature_content_enabled: true,
  created_at: "2026-09-01T00:00:00Z",
};

const PROFILES_KEY = ["profiles"] as const;
const LIBRARY_KEY = ["library", "series"] as const;

/**
 * Account A signed in with a profile picked and the app's caches warm, then
 * its session died without sign-out running: the global 401 handler only
 * nulls the current user, leaving everything else in place.
 */
function expiredSessionOfA(): QueryClient {
  const queryClient = new QueryClient();
  const store = useActiveProfileStore.getState();
  store.bindSessionUser(1);
  store.setActiveProfile(PROFILE_OF_A);
  queryClient.setQueryData(CURRENT_USER_QUERY_KEY, user(1));
  queryClient.setQueryData(PROFILES_KEY, [PROFILE_OF_A]);
  queryClient.setQueryData(LIBRARY_KEY, ["a-series"]);
  queryClient.setQueryData(CURRENT_USER_QUERY_KEY, null);
  return queryClient;
}

describe("adoptSignedInUser", () => {
  beforeEach(() => {
    useActiveProfileStore.setState({ activeProfile: null, ownerUserId: null, sessionUserId: null });
  });

  it("a different account signing in after an expired session starts clean", () => {
    const queryClient = expiredSessionOfA();

    adoptSignedInUser(queryClient, user(2));

    // The picker must not be offered A's profiles, nor the stale-profile
    // check be able to vouch for one of them.
    expect(queryClient.getQueryData(PROFILES_KEY)).toBeUndefined();
    expect(queryClient.getQueryData(LIBRARY_KEY)).toBeUndefined();
    const state = useActiveProfileStore.getState();
    expect(state.activeProfile).toBeNull();
    expect(state.sessionUserId).toBe(2);
    expect(queryClient.getQueryData(CURRENT_USER_QUERY_KEY)).toEqual(user(2));
  });

  it("the same account signing back in keeps its profile and caches", () => {
    const queryClient = expiredSessionOfA();

    adoptSignedInUser(queryClient, user(1));

    expect(queryClient.getQueryData(PROFILES_KEY)).toEqual([PROFILE_OF_A]);
    expect(queryClient.getQueryData(LIBRARY_KEY)).toEqual(["a-series"]);
    expect(useActiveProfileStore.getState().activeProfile?.id).toBe(PROFILE_OF_A.id);
    expect(queryClient.getQueryData(CURRENT_USER_QUERY_KEY)).toEqual(user(1));
  });

  it("the first sign-in on a tab drops nothing it did not have to", () => {
    const queryClient = new QueryClient();
    queryClient.setQueryData(BOOTSTRAP_QUERY_KEY, { needs_bootstrap: false });

    adoptSignedInUser(queryClient, user(2));

    expect(queryClient.getQueryData(BOOTSTRAP_QUERY_KEY)).toEqual({ needs_bootstrap: false });
    expect(useActiveProfileStore.getState().sessionUserId).toBe(2);
    expect(queryClient.getQueryData(CURRENT_USER_QUERY_KEY)).toEqual(user(2));
  });
});
