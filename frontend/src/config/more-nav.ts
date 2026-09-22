import {
  Activity,
  BarChart3,
  Bell,
  BookOpen,
  Bookmark,
  Heart,
  History,
  List,
  ScanText,
  Settings,
  Users,
  type LucideIcon,
} from "lucide-react";

export interface MoreItem {
  href: string;
  label: string;
  description: string;
  icon: LucideIcon;
  /** Hidden from non-admins. Instance-wide, not per-reader. See `nav.ts`. */
  adminOnly?: boolean;
}

export interface MoreSection {
  label: string;
  items: MoreItem[];
}

/**
 * The "More" hub — everything the five-tab bar cannot hold.
 *
 * The bottom bar mirrors the Flutter client's five destinations, which means
 * roughly a third of the app has no tab of its own. On desktop the sidebar
 * covers that; on a phone there is no sidebar, so without this screen those
 * routes would be reachable only by typing the URL. Grouped the same way as
 * `more_screen.dart` so the two clients read alike.
 */
export const moreSections: MoreSection[] = [
  {
    label: "Discover",
    items: [
      {
        href: "/updates",
        label: "Updates",
        description: "New chapters the checker has found.",
        icon: Bell,
      },
      {
        href: "/library/browse",
        label: "Browse all",
        description: "Every series on this server, filterable.",
        icon: BookOpen,
      },
      {
        href: "/library/collections",
        label: "Collections",
        description: "Your own groupings of series.",
        icon: List,
      },
      {
        href: "/library/recommendations",
        label: "Find something to read",
        description: "Describe what you feel like; get suggestions.",
        icon: Heart,
      },
    ],
  },
  {
    label: "Library",
    items: [
      {
        href: "/library/history",
        label: "Reading History",
        description: "Revisit everything you've read, most recent first.",
        icon: History,
      },
      {
        href: "/library/bookmarks",
        label: "Bookmarks",
        description: "Pages you marked to come back to.",
        icon: Bookmark,
      },
      {
        href: "/library/statistics",
        label: "Statistics",
        description: "Reading time, streak, and pace.",
        icon: BarChart3,
      },
      {
        href: "/ocr",
        label: "OCR Search",
        description: "Search the text inside your chapters.",
        icon: ScanText,
      },
    ],
  },
  {
    label: "Account",
    items: [
      {
        href: "/profiles",
        label: "Switch profile",
        description: "Each profile keeps its own library and progress.",
        icon: Users,
      },
      {
        href: "/settings",
        label: "Settings",
        description: "Design, theme, reader, mature content, and shortcuts.",
        icon: Settings,
      },
      {
        href: "/admin/status",
        label: "System Status",
        description: "Backend health, the update checker, and the queue.",
        icon: Activity,
        adminOnly: true,
      },
    ],
  },
];
