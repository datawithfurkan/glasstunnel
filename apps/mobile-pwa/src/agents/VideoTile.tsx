import { useEffect, useRef } from 'react';

interface Props {
  stream: MediaStream;
  muted?: boolean;
  autoPlay?: boolean;
  playsInline?: boolean;
  fill?: boolean;
}

export function VideoTile({ stream, muted = true, autoPlay = true, playsInline = true, fill }: Props) {
  const ref = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (el.srcObject !== stream) {
      el.srcObject = stream;
    }
  }, [stream]);
  return (
    <video
      ref={ref}
      muted={muted}
      autoPlay={autoPlay}
      playsInline={playsInline}
      className={fill ? 'w-full h-full object-contain' : 'max-w-full max-h-full'}
    />
  );
}
