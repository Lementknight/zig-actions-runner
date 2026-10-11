import { Link } from 'wouter'

/**
 * An id the API does not know (R17). Says what was looked for and offers the way back,
 * in the app's bordered box so it reads like the rest of the page.
 */
export function NotFound({
  title,
  body,
  backHref = '/',
  backLabel = 'Go to all workflow runs',
}: {
  title: string
  body: string
  backHref?: string
  backLabel?: string
}) {
  return (
    <div className="ar-box">
      <div className="ar-blankslate">
        <h2 className="ar-blankslate__title">{title}</h2>
        <p className="ar-blankslate__body">
          {body} <Link href={backHref}>{backLabel}</Link>.
        </p>
      </div>
    </div>
  )
}
