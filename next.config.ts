import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Documents are uploaded through a server action; Next's default body limit is 1 MB. The application itself refuses anything above 4 MB
  // (Vercel functions cap request bodies at 4.5 MB), so this only has to admit that size plus form overhead.
  experimental: { serverActions: { bodySizeLimit: '5mb' } },
};

export default nextConfig;
