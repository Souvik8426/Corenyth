#!/usr/bin/env python3
"""Score recorded synthetic SQLite runs. Never substitutes model outputs.
Unimplemented checks are reported as incomplete, never counted as passes.
"""
import json,sys,datetime,collections,pathlib
path=pathlib.Path(sys.argv[1]); run=json.loads(path.read_text()); split='heldout' if 'heldout' in path.name else 'dev'
cases={c['id']:c for c in map(json.loads,open(f'eval/corpus/single_{split}.jsonl'))}
def epoch(v): return int(datetime.datetime.fromisoformat(v).replace(tzinfo=datetime.timezone(datetime.timedelta(minutes=330))).timestamp()*1000)
def day(v): return datetime.datetime.fromtimestamp(v/1000,datetime.timezone(datetime.timedelta(minutes=330))).strftime('%Y-%m-%d') if v else ''
def check(e,r):
 b,a=r['before'],r['after']; reply=r['reply'].lower(); refs=r['refs']; errors=[]; incomplete=[]
 def fail(ok,msg):
  if not ok: errors.append(msg)
 def row(ref,state=a):
  rr=refs.get(ref,{}); return next((x for x in state.get(rr.get('table'),[]) if x['id']==rr.get('id')),None)
 def has(row,field,terms): return row is not None and all(t.lower() in str(row.get(field,'')).lower() for t in terms)
 def domain_row(x): return {k:v for k,v in x.items() if k not in ['last_accessed_at','updated_at']}
 changed={t:[x for x in a[t] if domain_row(x) not in [domain_row(y) for y in b[t]]] for t in ['tasks','reminders','memories']}
 domain_changed=any(changed.values()) or any(len(a[t])!=len(b[t]) for t in changed)
 if e['kind'] in ['reply','answer','clarify','none']: fail(not domain_changed,'unexpected domain write')
 if e['kind']=='clarify':
  fail('?' in reply,'missing clarification question')
  field=e.get('clarify',{}).get('field')
  cues={'time':['when','time','date','which day'],'title':['what','about'],'target':['which','what','who'],'conflict':['which','when','time','conflict','disagree'],'confirm_complete':['complete','done'],'confirm_remove':['remove','delete'],'confirm_cancel':['cancel'],'action':['complete','cancel','remove','delete']}
  if field in cues: fail(any(s in reply for s in cues[field]),'wrong clarification field')
  else: incomplete.append('clarification semantic field '+str(field))
  for ref in e.get('clarify',{}).get('candidates',[]):
   rr=row(ref); fail(rr is not None and ('#'+str(rr['id']) in reply or str(rr.get('title','')).lower() in reply),'missing candidate '+ref)
 if 'pending' in e:
  pending=a['pending_clarifications']; fail(bool(pending),'missing persisted pending')
  value=' '.join(str(json.loads(x['draft']).get('title','')) for x in pending).lower()
  fail(all(t.lower() in value for t in e['pending'].get('title_has',[])),'wrong pending title')
  fail(all(t.lower() not in value for t in e['pending'].get('title_not',[])),'dirty pending title')
 if e['kind']=='write':
  fail(domain_changed,'missing write')
  for change in e.get('changes',[]):
   op=change['op']; target=None
   if op in ['create_reminder','create_task','create_daily']:
    table='reminders' if op=='create_reminder' else 'tasks'
    new=[x for x in a[table] if not any(y['id']==x['id'] for y in b[table])]
    targets=[x for x in new if has(x,'title',change.get('title_has',[])) and (op!='create_reminder' or x.get('kind','reminder')=='reminder')]
    fail(len(targets)==1,'missing/ambiguous '+op); target=targets[0] if len(targets)==1 else None
    if target:
     fail(all(t.lower() not in target['title'].lower() for t in change.get('title_not',[])),'dirty title')
     field='trigger_at' if table=='reminders' else 'due_at'
     if 'at' in change: fail(target[field]==epoch(change['at']),'wrong timestamp')
     if 'on' in change: fail(day(target[field])==change['on'],'wrong date')
     if op=='create_daily':
      fail(target.get('recurrence')=='daily','missing daily recurrence')
      fail(target.get('daily_minute')==change['minute_of_day'],'wrong daily minute')
      if 'until' in change: fail(day(target.get('deadline_at'))==change['until'],'wrong daily end date')
     if change.get('lead'):
      linked=[x for x in a['reminders'] if x.get('task_id')==target.get('task_id') and x.get('kind')=='pre' and x.get('enabled')]
      actual={(target['trigger_at']-x['trigger_at'])//60000 for x in linked}
      fail(set(change['lead']).issubset(actual),'requested early alert missing')
     if 'follow_up' in change:
      present=any(x.get('task_id')==target.get('task_id') and x.get('kind')=='follow_up' and x.get('enabled') for x in a['reminders'])
      fail(present==change['follow_up'],'wrong follow-up configuration')
     if 'scheduled' in change: incomplete.append('platform scheduling requires device evidence')
   elif op in ['complete_task','edit_task','delete_task','set_outcome','set_details']:
    target=row(change['task'])
    if op=='delete_task': fail(target is None,'task not deleted')
    elif op=='complete_task': fail(target is not None and target['status']=='done','task not complete')
    elif op=='set_outcome': fail(has(target,'outcome',change.get('has',[])),'outcome missing')
    elif op=='edit_task':
     fail(target!=row(change['task'],b),'task unchanged')
     if 'at' in change: fail(target is not None and target['due_at']==epoch(change['at']),'wrong moved time')
     fail(has(target,'title',change.get('title_has',[])),'wrong edited title')
    else: incomplete.append('event details')
    if change.get('outcome_has'): fail(has(target,'outcome',change['outcome_has']),'outcome missing')
    if change.get('cancels_alerts'): fail(not any(x['enabled'] and x['task_id']==refs[change['task']]['id'] for x in a['reminders']),'alerts still enabled')
   elif op=='cancel_reminder': fail(row(change['reminder']) is None or not row(change['reminder'])['enabled'],'reminder not cancelled')
   elif op in ['save_memory','supersede_memory']:
    fail(any(has(x,'content',change.get('has',[])) and x.get('status','active')=='active' for x in changed['memories']),'memory not saved')
    if op=='supersede_memory': fail(row(change['memory']) is not None and row(change['memory']).get('status')=='superseded','old memory not superseded')
   elif op=='delete_memory': fail(row(change['memory']) is None,'memory not deleted')
   else: incomplete.append('op '+op)
  # Unlisted task/reminder mutations are unsafe; reminder-linked task creation is expected.
  allowed={x['op'] for x in e.get('changes',[])}
  if changed['memories'] and not allowed.intersection({'save_memory','supersede_memory','delete_memory'}): fail(False,'unrequested memory write')
 if 'answer' in e:
  for ref in e['answer'].get('include',[]):
   rr=row(ref); value=str(rr.get('title',rr.get('content',''))).lower() if rr else ''
   fail(bool(value) and value in reply,'missing answer '+ref)
  for ref in e['answer'].get('exclude',[]):
   rr=row(ref); value=str(rr.get('title',rr.get('content',''))).lower() if rr else ''
   fail(not value or value not in reply,'excluded answer '+ref)
  for value in e['answer'].get('include_text',[]): fail(value.lower() in reply,'missing answer fact')
  for value in e['answer'].get('exclude_text',[]): fail(value.lower() not in reply,'excluded answer fact')
 for value in e.get('reply_has',[]): fail(value.lower() in reply,'missing reply fact')
 if e.get('about'): incomplete.append('groundedness rubric')
 if e.get('forbid') and domain_changed: incomplete.append('forbidden-op exhaustive check')
 return errors,incomplete
out=[]
for r in run['cases']:
 e=cases[r['id']]['expect']; options=[e]+e.get('also_ok',[])
 scores=[check(o,r) for o in options]; errors,incomplete=min(scores,key=lambda s:(len(s[0]),len(s[1])))
 if cases[r['id']].get('setup',{}).get('env'): incomplete.append('fixture environment needs dedicated device/harness check')
 out.append({'id':r['id'],'category':r['category'],'status':'fail' if errors else 'incomplete' if incomplete else 'pass','errors':errors,'unscored':incomplete})
counts=collections.Counter(x['status'] for x in out)
report={'mode':run['mode'],'split':split,'counts':dict(counts),'categories':{k:dict(collections.Counter(x['status'] for x in out if x['category']==k)) for k in sorted({x['category'] for x in out})},'cases':out}
path.with_name(path.stem+'-score.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='cases'},indent=2))
