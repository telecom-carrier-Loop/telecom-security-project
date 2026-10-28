const paths = {
  usage: 'M5 20V13M12 20V8M19 20V4',
  plans: 'M7 3h10v18H7zM10 17h4',
  billing: 'M3 6h18v13H3zM3 10h18M7 15h3',
  membership: 'M4 8h16v13H4zM3 5h18v4H3zM12 5v16M12 5C8-2 3 5 12 5s4-7 0 0',
  shop: 'M5 8h14l1 13H4zM9 8V6a3 3 0 016 0v2',
  support: 'M4 5h16v12H9l-5 4zM8 9h8M8 13h5',
  notice: 'M5 3h14v18H5zM8 8h8M8 12h8M8 16h5',
  arrow: 'M4 12h16M14 6l6 6-6 6',
  shield: 'M12 3l8 3v6c0 5-8 9-8 9S4 17 4 12V6zM8 12l3 3 5-6',
} as const
export type ServiceIconName = keyof typeof paths
export default function ServiceIcon({ name, size = 24 }: { name: ServiceIconName; size?: number }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={paths[name]} /></svg>
}
