import { Label } from '@primer/react'
import { PlayIcon } from '@primer/octicons-react'
import { Link, Route, Switch } from 'wouter'

// The three routes (R16). Each placeholder is replaced by its real view in a later unit:
// RunList (U5), RunPage (U6), JobView (U4).

function Placeholder({ title, body }: { title: string; body: string }) {
  return (
    <>
      <div className="ar-page-header">
        <h1 className="ar-page-title">{title}</h1>
      </div>
      <div className="ar-box">
        <div className="ar-blankslate">
          <p className="ar-blankslate__body">{body}</p>
        </div>
      </div>
    </>
  )
}

function NotFoundPage() {
  return (
    <div className="ar-box">
      <div className="ar-blankslate">
        <h1 className="ar-blankslate__title">Page not found</h1>
        <p className="ar-blankslate__body">
          There is nothing at this address. <Link href="/">Go to all workflow runs</Link>.
        </p>
      </div>
    </div>
  )
}

const dataSource = import.meta.env.VITE_DATA_SOURCE === 'http' ? 'http' : 'fake'

export default function App() {
  return (
    <>
      <header className="ar-app-header">
        <Link href="/" className="ar-app-header__brand">
          <PlayIcon size={24} />
          Zig runner
        </Link>
        <span className="ar-app-header__section">Actions</span>
        <span className="ar-app-header__spacer" />
        {dataSource === 'fake' && <Label variant="attention">Fake data</Label>}
      </header>
      <main className="ar-page">
        <Switch>
          <Route path="/">
            <Placeholder title="All workflows" body="Workflow runs will appear here." />
          </Route>
          <Route path="/runs/:id">
            {(params) => (
              <Placeholder title={`Run ${params.id}`} body="This run's jobs will appear here." />
            )}
          </Route>
          <Route path="/runs/:runId/jobs/:jobId">
            {(params) => (
              <Placeholder
                title={`Job ${params.jobId}`}
                body={`Steps and logs for job ${params.jobId} of run ${params.runId} will appear here.`}
              />
            )}
          </Route>
          <Route>
            <NotFoundPage />
          </Route>
        </Switch>
      </main>
    </>
  )
}
