module I = Lm_instrument

module Pos  = Omake_pos.Make (struct let name = "Omake_shell_job" end)


module IntCompare =
struct
   type t = int
   let compare = (-)
end

module IntSet   = Lm_set.LmMake (IntCompare)
module IntTable = Lm_map.LmMake (IntCompare)
module PidSet   = IntSet
module PidTable = IntTable

(*
 * Subjob info.
 *)
type job_state =
  | JobForeground
  | JobBackground
  | JobSuspended

type job_status =
  | JobExited of int
  | JobSignaled of int
  | JobStopped of int

type subjob_cond =
   { cond_op       : Omake_shell_type.pipe_op;
     cond_pipe     : Omake_env.string_pipe;
     cond_stdin    : Unix.file_descr;
     cond_stdout   : Unix.file_descr;
     cond_stderr   : Unix.file_descr
   }

and subjob_exp =
  | SubjobProcess of Omake_shell_sys_type.pid * Omake_env.t
  | SubjobPipe of subjob_exp * subjob_exp
  | SubjobFinished of job_status * Omake_env.t
  | SubjobCond of subjob_exp * subjob_cond

(*
 * Job info.
 * The job has an identifier,
 * a process group, and an expression of what to compute.
 *)
type job =
   { job_id              : int;
     job_pipe            : Omake_env.string_pipe option;
     mutable job_pgrp    : Omake_shell_sys_type.pgrp;
     mutable job_state   : job_state
   }

(*
 * Info for this shell.
 * There can be only one shell, and it has a controlling terminal.
 * Invariant: if the pid is 0, then this job controls the terminal.
 *)
type shell =
   { mutable shell_jobs : job IntTable.t }

(*
 * Global shell.
 *)
let shell =
   { shell_jobs = IntTable.empty }

(************************************************************************
 * Printing.
 *)

(*
 * Print a job state.
 *)
let pp_print_job_state buf state =
  let s =
    match state with
    | JobForeground ->
      "Running"
    | JobBackground ->
      "Background"
    | JobSuspended ->
      "Suspended"
  in
  Format.pp_print_string buf s

(*
 * Job may be a pipe.
 *)
let pp_print_pipe_option buf opt =
  match opt with
  | Some pipe ->
    Omake_env.pp_print_string_pipe buf pipe
  | None ->
    Format.pp_print_string buf "<thread>"

(*
 * Job status.
 *)
let pp_print_status buf code =
   match code with
      JobExited code ->
         Format.fprintf buf "exited with code %d" code
    | JobSignaled code ->
         Format.fprintf buf "exited with signal %d" code
    | JobStopped code ->
         Format.fprintf buf "stopped with code %d" code

(*
 * Print a job expression.
 *)
(* let rec pp_print_exp buf e = *)
(*    match e with *)
(*       SubjobProcess (pid, _) -> *)
(*          Format.fprintf buf "(%d)" pid *)
(*     | SubjobPipe (e1, e2) -> *)
(*          Format.fprintf buf "@[<hv 1>(%a@ | %a)@]" pp_print_exp e1 pp_print_exp e2 *)
(*     | SubjobCond (e, cond) -> *)
(*          let { cond_op = op; *)
(*                cond_pipe = pipe; *)
(*                _ *)
(*              } = cond *)
(*          in *)
(*             Format.fprintf buf "@[<hv 1>(%a)@ %a@ %a@]" (\**\) *)
(*                pp_print_exp e *)
(*                pp_print_pipe_op op *)
(*                Omake_env.pp_print_string_pipe pipe *)
(*     | SubjobFinished (code, _) -> *)
(*          Format.fprintf buf "[Finished: %a]" pp_print_status code *)

(*
 * Print a job.
 *)
let pp_print_job buf job =
   let { job_id    = id;
         job_pgrp  = pgrp;
         job_state = state;
         job_pipe  = pipe
       } = job
   in
      Format.fprintf buf "@[<v 3>[%d] (%d) %a@ - %a@]" (**)
         id
         pgrp
         pp_print_job_state state
         pp_print_pipe_option pipe

(*
 * Status code printing.
 *)
let print_exit_code venv force pid code =
   match code with
      JobExited 0 ->
         if force then
            Format.eprintf "- %d: done@." pid
    | JobExited code ->
         if force || Omake_env.venv_defined venv Omake_var.printexitvalue_var then
            Format.eprintf "- %d: exited with code %d@." pid code
    | JobSignaled code ->
         Format.eprintf "- %d: terminated with signal %d@." pid code
    | JobStopped code ->
         Format.eprintf "- %d: stopped with code %d@." pid code

(************************************************************************
 * Utilities
 *)

(*
 * Get an array representation of the environment.
 *)
let array_of_env env fields =
   let env =
      List.fold_left
        (fun env (v, x) -> Lm_symbol.SymbolTable.add env v x) env fields in
   let env =
     Lm_symbol.SymbolTable.fold (fun env v x ->
         Printf.sprintf "%s=%s" (Lm_symbol.string_of_symbol v) x :: env) [] env
   in
      Array.of_list env

(*
 * Figure out a common code.
 * For now, signaling takes precedence.
 *)
let unify_codes code1 code2 =
   match code1, code2 with
      JobSignaled code1, JobSignaled code2 ->
         JobSignaled (max code1 code2)
    | JobSignaled _, _ ->
         code1
    | _, JobSignaled _ ->
         code2
    | JobExited code1, JobExited code2 ->
         JobExited (max code1 code2)
    | _, JobExited _ ->
         code2
    | _ ->
         code1

(*
 * Get an integer version of the code.
 *)
let int_of_code code =
   match code with
      JobSignaled code
    | JobExited code
    | JobStopped code ->
         code

(*
 * Find the job with the process group.
 *)
let find_job_by_pgrp pgrp =
   match
      IntTable.fold (fun job1 _ job2 ->
            if job2.job_pgrp = pgrp then
               Some job2
            else
               job1) None shell.shell_jobs
   with
      Some job ->
         job
    | None ->
         raise Not_found

(************************************************************************
 * Job management.
 *)

(*
 * Create a new job.
 *)
let new_job pgrp pipe =
   let rec new_id i =
      if IntTable.mem shell.shell_jobs i then
         new_id (succ i)
      else
         i
   in
   let id = new_id 1 in
   let job =
      { job_id      = id;
        job_pipe    = pipe;
        job_pgrp    = pgrp;
        job_state   = JobForeground
      }
   in
      shell.shell_jobs <- IntTable.add shell.shell_jobs id job;
      job

(*
 * Remove a job from the shell.
 *)
let remove_job job =
   shell.shell_jobs <- IntTable.remove shell.shell_jobs job.job_id

(*
 * Create a simple thread.
 * We have a function and channels.
 *)
let create_top_thread _ f stdin stdout stderr =
   if !Omake_shell_type.debug_shell then
      Format.eprintf "create_top_thread@.";
   let apply_fun stdin stdout stderr _ =
      f stdin stdout stderr
   in
   let thread_info : Omake_shell_sys_type.create_thread =
      {create_thread_stdin      = stdin;
        create_thread_stdout     = stdout;
        create_thread_stderr     = stderr;
        create_thread_pgrp       = 0;
        create_thread_fun        = apply_fun;
        create_thread_background = true
      }
   in
      Omake_shell_sys.create_thread thread_info

(*
 * Create the diversion channels.
 *)
let string_of_redirect (chan : string Omake_shell_type.redirect) =
  match chan with
  | RedirectNode node ->
    Some (Omake_node.Node.fullname node)
  | RedirectArg s ->
    Some s
  | RedirectNone ->
    None

let create_channels stdin stdin_file append stdout stdout_file stderr_divert stderr =
   let stdin, close_stdin =
      match string_of_redirect stdin_file with
         Some file ->
            Lm_unix_util.openfile file [Unix.O_RDONLY; Unix.O_NOCTTY] 0, true
       | None ->
            stdin, false
   in
   let stdout, close_stdout =
      match string_of_redirect stdout_file with
         Some file ->
            let flags = [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_NOCTTY] in
            let flags =
               if append then
                  Unix.O_APPEND :: flags
               else
                  Unix.O_TRUNC :: flags
            in
               (try Lm_unix_util.openfile file flags 0o666, true with
                   exn ->
                      if close_stdin then
                         Omake_shell_sys.close_fd stdin;
                      raise exn)
       | None ->
            stdout, false
   in
   let () =
      if append then
         ignore (Unix.lseek stdout 0 Unix.SEEK_END)
   in
   let stderr =
      if stderr_divert then
         stdout
      else
         stderr
   in
      stdin, close_stdin, stdout, close_stdout, stderr

(*
 * Application at the toplevel.
 * Don't create a thread.
 *)
(* let restore_vars = [stdin_sym; stdout_sym; stderr_sym] *)

let create_apply_top venv stdin stdout stderr apply =
  match apply with 
    { 
      Omake_shell_type.apply_env = env;
      apply_fun = f;
      apply_args = args;
      apply_stdin = stdin_file;
      apply_stdout = stdout_file;
      apply_stderr = stderr_divert;
      apply_append = append;
      _
    } -> 
    let stdin, close_stdin, stdout, close_stdout, stderr =
      create_channels stdin stdin_file append stdout stdout_file stderr_divert stderr
    in
    let cleanup () =
      if close_stdin then
        Omake_shell_sys.close_fd stdin;
      if close_stdout then
        Omake_shell_sys.close_fd stdout
    in
    (* The function will close its files on its own *)
    try
      if !Omake_shell_type.debug_shell then
        Format.eprintf "create_apply_top pid=%i: duplicating channels@." (Unix.getpid ());
      let stdin  = Unix.dup stdin in
      let stdout = Unix.dup stdout in
      let stderr = Unix.dup stderr in
      let info = f venv stdin stdout stderr env args in
      if !Omake_shell_type.debug_shell then
        Format.eprintf "create_apply_top pid=%i: done@." (Unix.getpid ());
      cleanup ();
      info
    with
      Omake_value_type.ExitException (_, code) ->
      if !Omake_shell_type.debug_shell then
        Format.eprintf "create_apply_top pid=%i: exit exception: %i@." (Unix.getpid ()) code;
      cleanup ();
      code, venv, Omake_value_type.ValOther (ValExitCode code)
    | Omake_value_type.ExitParentException (pos, code) ->
      if !Omake_shell_type.debug_shell then
        Format.eprintf "create_apply_top pid=%i: exit from parent exception: %i@." (Unix.getpid ()) code;
      cleanup ();
      raise (Omake_value_type.ExitException (pos, code))
    | exn ->
      if !Omake_shell_type.debug_shell then
        Format.eprintf "create_apply_top pid=%i: error: %a@." (Unix.getpid ()) Omake_exn_print.pp_print_exn exn;
      cleanup ();
      raise exn

(*
 * Start an application in a particular subjob.
 *)
let create_apply venv pgrp bg stdin stdout stderr apply =
  if !Omake_shell_type.debug_shell then
    Format.eprintf "create_apply@.";
  let { 
    Omake_shell_type. apply_env = env;
    apply_fun = f;
    apply_args = args;
    apply_stdin = stdin_file;
    apply_stdout = stdout_file;
    apply_stderr = stderr_divert;
    apply_append = append;
    _
  } = apply
  in
  let stdin, close_stdin, stdout, close_stdout, stderr =
    create_channels stdin stdin_file append stdout stdout_file stderr_divert stderr
  in

  (* The actual function call *)
  let apply_fun stdin stdout stderr _ =
    let code, _, _ = f venv stdin stdout stderr env args in
    code
  in
  let thread_info : Omake_shell_sys_type.create_thread =
    { create_thread_stdin = stdin;
      create_thread_stdout = stdout;
      create_thread_stderr = stderr;
      create_thread_pgrp = pgrp;
      create_thread_fun = apply_fun;
      create_thread_background = bg
    }
  in
  let cleanup () =
    if close_stdin then
      Omake_shell_sys.close_fd stdin;
    if close_stdout then
      Omake_shell_sys.close_fd stdout
  in
  try
    let pid = Omake_shell_sys.create_thread thread_info in
    cleanup ();
    pid
  with
    exn ->
    cleanup ();
    raise exn

(*
 * Resolve the absolute name of the executable.
 *)
let find_executable_string venv pos loc exe =
  let pos = Pos.string_pos "find_executable" pos in
  let cache = Omake_env.venv_cache venv in
  if not (Filename.is_relative exe) || Lm_string_util.contains_any exe Lm_filename_util.separators then
    let rec resolve_exe = function
        suff :: suffixes ->
        let node = Omake_env.venv_intern venv PhonyProhibited (exe ^ suff) in
        if Omake_cache.exists cache node then
          node
        else
          resolve_exe suffixes
      | [] ->
        raise (Omake_value_type.OmakeException 
                 (Pos.loc_pos loc pos, StringStringError ("command not found", exe)))
    in
    resolve_exe Omake_cache.exe_suffixes
  else
    let path = Omake_env.venv_find_var venv pos loc Omake_var.path_var in
    let path = Omake_eval.path_of_values venv pos (Omake_value.values_of_value venv pos path) "." in
    let path = Omake_cache.ls_exe_path cache path in
    try Omake_cache.exe_find cache path exe with
      Not_found ->
      raise (Omake_value_type.OmakeException (Pos.loc_pos loc pos, StringStringError ("command not found in PATH", exe)))

let find_executable venv pos loc (exe : Omake_shell_type.simple_exe) =
  let node =
    match exe with
    | ExeQuote exe
    | ExeString exe ->
      find_executable_string venv pos loc exe
    | ExeNode node ->
      if Omake_cache.exe_suffixes = [""] || 
         Omake_cache.exists 
           (Omake_env.venv_cache venv) ~force:true node then
        node
      else
        find_executable_string venv pos loc (Omake_node.Node.absname node)
  in
  Omake_node.Node.absname node

(*
 * Start a command.
 *)
let create_command venv pgrp bg stdin stdout stderr 
    (command : (Omake_shell_type.simple_exe, string, string) Omake_shell_type.poly_cmd) =
  match command with 
    { cmd_loc = loc;
      cmd_env = env;
      cmd_exe = exe;
      cmd_argv = argv;
      cmd_stdin = stdin_file;
      cmd_stdout = stdout_file;
      cmd_append = append;
      cmd_stderr = stderr_divert
    } -> 

    let pos = Pos.string_pos "Omake_shell_job.create_command" (Pos.loc_exp_pos loc) in
    let exe = find_executable venv pos loc exe in
    let stdin, close_stdin, stdout, close_stdout, stderr =
      create_channels stdin stdin_file append stdout stdout_file stderr_divert stderr
    in
    let dir = Omake_node.Dir.absname (Omake_env.venv_dir venv) in

    (* Create a process *)
    let current_env = Omake_env.venv_environment venv in
    let proc_info : Omake_shell_sys_type.create_process =
      { create_process_stdin  = stdin;
        create_process_stdout = stdout;
        create_process_stderr = stderr;
        create_process_pgrp   = pgrp;
        create_process_env    = array_of_env current_env env;
        create_process_dir    = dir;
        create_process_exe    = exe;
        create_process_argv   = Array.of_list (exe :: argv);
        create_process_background = bg
      }
    in
    let cleanup () =
      if close_stdin then
        Omake_shell_sys.close_fd stdin;
      if close_stdout then
        Omake_shell_sys.close_fd stdout
    in
    if !Omake_shell_type.debug_shell then
      Format.eprintf "Creating command: %s@." exe;
    try
      let pid = Omake_shell_sys.create_process proc_info in
      cleanup ();
      if !Omake_shell_type.debug_shell then
        Format.eprintf "Command created: pid=%i@." pid;
      pid
    with
      exn ->
      cleanup ();
      begin match exn with
          Failure err ->
          let format_error buf =
            Format.fprintf buf "@[<hv3>Spawning %s failed:@ %s@]" exe err
          in
          raise (Omake_value_type.OmakeException(pos, LazyError format_error))
        | Unix.Unix_error(err, cmd, arg) ->
          let format_error buf =
            Format.fprintf buf "@[<hv3>Spawning %s failed:@ @[<hv3>%s" exe cmd;
            if (arg <> "") then
              Format.fprintf buf "@ %s" arg;
            Format.fprintf buf ":@ %s@]@]" (Unix.error_message err)
          in
          raise (Omake_value_type.OmakeException(pos, LazyError format_error))
        | _ ->
          raise exn
      end

(*
 * Evaluate a conditional, to see if the conditional operation should be performed.
 *)
let cond_continue (op : Omake_shell_type.pipe_op) (x :  job_status ) = 
  match x with
  |  JobExited 0 ->
    (match op with
       Omake_shell_type.PipeAnd
     | PipeSequence ->
       true
     | PipeOr ->
       false)
  | JobExited _ ->
    (match op with
       PipeOr
     | PipeSequence ->
       true
     | PipeAnd ->
       false)
  | _ ->
    false


let probe_create_thread = I.create "job.create_thread"
let probe_create_process = I.create "job.create_process"
let probe_create_job = I.create "job.create_job"

(*
 * Create a conditional.
 *)
let rec create_cond venv pgrp stdin stdout stderr op pipe1 pipe2 =
   let cond =
      { cond_op     = op;
        cond_pipe   = pipe2;
        cond_stdin  = stdin;
        cond_stdout = stdout;
        cond_stderr = stderr
      }
   in
   let exp = create_pipe_aux venv pgrp false stdin stdout stderr pipe1 in
      SubjobCond (exp, cond)

(*
 * Create an actual pipe.
 *)
and create_compose venv pgrp stdin stdout stderr divert_stderr pipe1 pipe2 =
   let stdin', stdout' = Unix.pipe () in
   let stderr' =
      if divert_stderr then
         stdout'
      else
         stderr
   in
   let () = Omake_shell_sys.set_close_on_exec stdout' in
   let exp2 = 
      try create_pipe_aux venv pgrp true stdin' stdout stderr pipe2 with
         exn ->
            Omake_shell_sys.close_fd stdin';
            Omake_shell_sys.close_fd stdout';
            raise exn
   in
   let () = Omake_shell_sys.close_fd stdin' in
   let () = Omake_shell_sys.clear_close_on_exec stdout' in
   let exp1 = 
      try
         create_pipe_aux venv pgrp true stdin stdout' stderr' pipe1
      with 
         Omake_value_type.OmakeException _
       | Unix.Unix_error _
       | Failure _ as exn ->
            Format.eprintf "%a@." Omake_exn_print.pp_print_exn exn;
            SubjobFinished (JobExited Omake_state.exn_error_code, venv)
       | exn ->
            Omake_shell_sys.close_fd stdout';
            ignore(wait_exp pgrp exp2);
            raise exn
   in
      Omake_shell_sys.close_fd stdout';
      SubjobPipe (exp1, exp2)

(*
 * Create a subshell.
 *)
and create_shell venv pgrp bg stdin stdout stderr pipe =
   if !Omake_shell_type.debug_shell then
      Format.eprintf "create_shell@.";
   let create_fun stdin stdout stderr pgrp =
      let exp =
         try
            create_pipe_aux venv pgrp false stdin stdout stderr pipe
         with
            Omake_value_type.ExitException (_, code) ->
               SubjobFinished (JobExited code, venv)
          | exn ->
               Format.eprintf "@[<v 0>%a@ Process group exception.@]@." Omake_exn_print.pp_print_exn exn;
               raise exn
      in
      let code = wait_exp pgrp exp in
         Omake_shell_sys.close_fd stdin;
         Omake_shell_sys.close_fd stdout;
         Omake_shell_sys.close_fd stderr;
         code
   in
   let thread_info : Omake_shell_sys_type.create_thread =
      { create_thread_stdin  = stdin;
        create_thread_stdout = stdout;
        create_thread_stderr = stderr;
        create_thread_pgrp   = pgrp;
        create_thread_fun    = create_fun;
        create_thread_background = bg
      }
   in
      Omake_shell_sys.create_thread thread_info

(*
 * Create a grouped operation.
 *)
and create_group venv pgrp stdin stdout stderr group =
   if !Omake_shell_type.debug_shell then
      Format.eprintf "create_group@.";
   let { Omake_shell_type.group_stdin = stdin_file;
         group_stdout = stdout_file;
         group_stderr = stderr_divert;
         group_append = append;
         group_pipe = pipe
       } = group
   in
   let stdin, close_stdin, stdout, close_stdout, stderr =
      create_channels stdin stdin_file append stdout stdout_file stderr_divert stderr
   in
   let create_fun stdin stdout stderr pgrp =
      let exp =
         try 
            create_pipe_aux venv pgrp false stdin stdout stderr pipe
         with
            Omake_value_type.ExitException (_, code) ->
               SubjobFinished (JobExited code, venv)
          | exn ->
               Format.eprintf "@[<v 0>%a@ Process group exception.@]@." Omake_exn_print.pp_print_exn exn;
               raise exn
      in
      let code = wait_exp pgrp exp in
         Omake_shell_sys.close_fd stdin;
         Omake_shell_sys.close_fd stdout;
         Omake_shell_sys.close_fd stderr;
         code
   in
   let thread_info : Omake_shell_sys_type.create_thread =
      { create_thread_stdin  = stdin;
        create_thread_stdout = stdout;
        create_thread_stderr = stderr;
        create_thread_pgrp   = pgrp;
        create_thread_fun    = create_fun;
        create_thread_background = true
      }
   in
   let pid = Omake_shell_sys.create_thread thread_info in
      if close_stdin then
         Omake_shell_sys.close_fd stdin;
      if close_stdout then
         Omake_shell_sys.close_fd stdout;
      (* Groups are suposed to be in a separate scope, use the original venv *)
      SubjobProcess (pid, venv)

(*
 * Create the pipe.
 *)
and create_pipe_aux venv pgrp fork stdin stdout stderr pipe =
   if !Omake_shell_type.debug_shell then
      Format.eprintf "create_pipe_aux (fork: %b): %a@." fork Omake_env.pp_print_string_pipe pipe;
   match pipe with
      PipeApply (_, apply) ->
         if fork then
            SubjobProcess (create_apply venv pgrp true stdin stdout stderr apply, venv)
         else
            let code, venv, _ = create_apply_top venv stdin stdout stderr apply in
               SubjobFinished (JobExited code, venv)
    | PipeCommand (_, command) ->
         SubjobProcess (create_command venv pgrp true stdin stdout stderr command, venv)
    | PipeCond (_, op, pipe1, pipe2) ->
         if fork then
            SubjobProcess (create_shell venv pgrp true stdin stdout stderr pipe, venv)
         else
            create_cond venv pgrp stdin stdout stderr op pipe1 pipe2
    | PipeCompose (_, divert_stderr, pipe1, pipe2) ->
         create_compose venv pgrp stdin stdout stderr divert_stderr pipe1 pipe2
    | PipeGroup (_, group) ->
         create_group venv pgrp stdin stdout stderr group
    | PipeBackground (_, pipe) ->
         create_pipe_aux venv pgrp true stdin stdout stderr pipe

(*
 * Create a thread.  This may actually be a separate
 * process.
 *)
and create_thread venv f stdin stdout =
   I.instrument probe_create_thread (fun stderr ->
   if !Omake_shell_type.debug_shell then
      Format.eprintf "Creating thread@.";

   (* Evaluate application eagerly *)
   let pgrp = create_top_thread venv f stdin stdout stderr in
   let job  = new_job pgrp None in
      if !Omake_shell_type.debug_shell then
         Format.eprintf "Started thread with pgrp %i, internal id %i@." job.job_pgrp job.job_id;
      job.job_state <- JobBackground;
      Omake_env.InternalPid job.job_id
  )

(*
 * Wait for a subjob to finish.
 * This is only executed in a subprocess,
 * so the appropriate thing to do when finished
 * is exit.
 *)
and wait_exp pgrp exp =
   match eval_exp_top pgrp exp with
      SubjobFinished (JobExited code, _)
    | SubjobFinished (JobSignaled code, _) ->
         if !Omake_shell_type.debug_shell then
            Format.eprintf "wait_exp: %i exiting %d@." (Unix.getpid()) code;
         code
    | exp ->
         wait_exp2 pgrp exp

and wait_exp2 pgrp exp =
   (* Wait for a job to complete; ignore stopped processes *)
   if !Omake_shell_type.debug_shell then
      Format.eprintf "wait_exp2: %i waiting for pgrp %i@." (Unix.getpid()) pgrp;
   let code =
      try Some (Omake_shell_sys.wait pgrp false false) with
         Unix.Unix_error (Unix.EINTR, _, _) ->
            None
   in
      if !Omake_shell_type.debug_shell then
         Format.eprintf "wait_exp: some event happened@.";
      match code with
         None
       | Some (_, Unix.WSTOPPED _) ->
            wait_exp2 pgrp exp
       | Some (pid, (Unix.WEXITED _| Unix.WSIGNALED _ as code)) ->
            let code =
               match code with
                  Unix.WEXITED code -> JobExited code
                | Unix.WSIGNALED code -> JobSignaled code
                | Unix.WSTOPPED _ -> raise (Invalid_argument "Omake_shell_job.wait_exp2: internal error")
            in
               (* Evaluate the expression *)
               if !Omake_shell_type.debug_shell then
                  Format.eprintf "wait_exp2: %i handling event: pid=%d@." (Unix.getpid()) pid;
               let exp = eval_exp pgrp exp pid code in
                  wait_exp pgrp exp

(*
 * Evaluate the expression.
 *)
and eval_exp_top pgrp e =
   eval_exp pgrp e 0 (JobExited 0)

and eval_exp pgrp e pid code =
   if !Omake_shell_type.debug_shell then
      Format.eprintf "eval_exp in %i: pgrp=%i, pid=%i@." (Unix.getpid()) pgrp pid;
   let rec eval e =
      match e with
         SubjobProcess (pid', venv) ->
            if pid' = pid then
               SubjobFinished (code, venv)
            else
               e
       | SubjobPipe (e1, e2) ->
            (match eval e1, eval e2 with
                SubjobFinished (code1, _), SubjobFinished (code2, venv) ->
                   SubjobFinished (unify_codes code1 code2, venv)
              | e1, e2 ->
                   SubjobPipe (e1, e2))
       | SubjobCond (e, cond) ->
            if !Omake_shell_type.debug_shell then Format.eprintf "eval_exp in %i: evaluating SubjobCond@." (Unix.getpid());
            (match eval e with
                SubjobFinished (code, venv) ->
                   let { cond_op     = op;
                         cond_pipe   = pipe;
                         cond_stdin  = stdin;
                         cond_stdout = stdout;
                         cond_stderr = stderr
                       } = cond
                   in
                      if cond_continue op code then
                         eval_exp_top pgrp (create_pipe_aux venv pgrp false stdin stdout stderr pipe)
                      else
                         SubjobFinished (code, venv)
              | e ->
                   SubjobCond (e, cond))
       | SubjobFinished _ ->
            e
   in
      eval e

(*
 * Utility function for wait_top_aux and cleanup_top_aux
 *)
let finalize_job job = function
   Unix.WEXITED code ->
      remove_job job;
      JobExited code
 | Unix.WSIGNALED code ->
      remove_job job;
      JobSignaled code
 | Unix.WSTOPPED code ->
      job.job_state <- JobSuspended;
      JobStopped code

(*
 * Wait for a job to finish.
 * This is executed in the main process.
 * Do not give away the terminal.
 *)
let rec wait_top_aux job =
   let pgrp = job.job_pgrp in
   if !Omake_shell_type.debug_shell then
      Format.eprintf "wait_top_aux: will wait for pgrp %i@." pgrp;
   let pid, status = Omake_shell_sys.wait pgrp true false in
      if !Omake_shell_type.debug_shell then
         Format.eprintf "wait_top_aux: got pid %d@." pid;
      if pid <> pgrp then
         wait_top_aux job
      else
         let code = finalize_job job status in
            if !Omake_shell_type.debug_shell then
               Format.eprintf "wait_top_aux: %a@." pp_print_status code;
            code, status

let wait_top venv job =
  let code, _ = wait_top_aux job in
  Omake_shell_sys.set_tty_pgrp 0;
  print_exit_code venv false job.job_id code;
  code

let wait_pid _ job =
  let _, status = wait_top_aux job in
  Omake_shell_sys.set_tty_pgrp 0;
  status

(*
 * Create a pipe.
 * If this is a simple job, do not monitor the pipe.
 *)
let rec create_pipe_exn venv bg stdin stdout stderr = function
  | Omake_shell_type.PipeApply (_, apply) ->
    create_apply venv 0 bg stdin stdout stderr apply
  | PipeCommand (_, command) ->
    create_command venv 0 bg stdin stdout stderr command
  | PipeCond _
  | PipeCompose _
  | PipeGroup _ as pipe ->
    create_shell venv 0 bg stdin stdout stderr pipe
  | PipeBackground (_, pipe) ->
    create_pipe_exn venv true stdin stdout stderr pipe

(*
 * When the pipe is created:
 * If the pipe is in the background, the terminal remains attached.
 * If the pipe is not in the background, we retain control of the terminal.
 *
 * WARNING: this function should not be called if
 *    1. the pipeline is an alias, and
 *    2. the output is a pipe connected internally.
 * The reason is that the alias is not processed in a thread.
 * If it generates a lot of output, it will block, causing
 * deadlock because the output processor is not being run.
 *
 * Remember that rules pass their output to the output
 * processor through a pipe like this.  However, commands
 * in rules are processed by create_process, not create_job.
 *)
let rec create_job_aux venv pipe stdin stdout stderr =
   if !Omake_shell_type.debug_shell then
      Format.eprintf "Creating pipe: %a@." Omake_env.pp_print_string_pipe pipe;

   match pipe with
      PipeApply (_, apply) ->
         (* Evaluate applications eagerly *)
         create_apply_top venv stdin stdout stderr apply
    | PipeBackground (_, pipe) ->
         (* Create a background job *)
         let pgrp = create_pipe_exn venv true stdin stdout stderr pipe in
         let job  = new_job pgrp (Some pipe) in
            job.job_state <- JobBackground;
            0, venv, ValNone
    | PipeCompose _
      (*
       * XXX: TODO (Aleksey 2007/06/26) 
       * PipeCompose should be handled similar to PipeCond, where only the left hand
       * side should be forked, while the right hand side should be evaluated in the current process.
       *)
    | PipeGroup _
    | PipeCommand _ ->
         (* Otherwise, fork a foreground job *)
         let pgrp = create_pipe_exn venv false stdin stdout stderr pipe in
         let job  = new_job pgrp (Some pipe) in
            if !Omake_shell_type.debug_shell then
               Format.eprintf "Running pgrp %d (my pid = %d)@." pgrp (Unix.getpid ());
            (*
             * On Mac OSX this call fails with EPERM.
             * I believe this is because the sub-process
             * sets the controlling terminal itself (see
             * Omake_shell_sys_unix.create_process).
             *
             * This means that the sub-process takes over the terminal,
             * and we can't set it anymore.
             *
             * This seems like a bogus explanation, because we have
             * to get the terminal back on suspend...
            Omake_shell_sys.set_tty_pgrp pgrp;
             *)
            let code = int_of_code (wait_top venv job) in
               code, venv, ValOther (ValExitCode code)
    | PipeCond (_, op, pipe1, pipe2) ->
         let (code, venv, _) as info = create_job_aux venv pipe1 stdin stdout stderr in
            if cond_continue op (JobExited code) then
               create_job_aux venv pipe2 stdin stdout stderr
            else
               info

let create_job venv pipe stdin stdout =
   I.instrument probe_create_job (fun stderr ->
   let _, venv, value = create_job_aux venv pipe stdin stdout stderr in
      venv, value
   )

let is_pipe fd =
  (* we assume that fd is a pipe when fd is not seekable. This is for an
     optimization only; returning true is always possible, but we must only
     return false when no separate thread is needed
   *)
  try
    ignore(Unix.lseek fd 0 Unix.SEEK_CUR);
    false
  with
    | Unix.Unix_error(Unix.ESPIPE,_,_) -> true

(*
 * This is a variation: create the process and return the pid.
 * These jobs are always background.
 *)
let create_process venv pipe stdin stdout =
  I.instrument probe_create_process (fun stderr ->
  if !Omake_shell_type.debug_shell then
    Format.eprintf "Creating process: %a@." Omake_env.pp_print_string_pipe pipe;
  match pipe with
      (*
       * The restriction to stdout and stderr is necessary to
       * prevent possible blocking on I/O.
       *)
    PipeApply (_, apply) when not(is_pipe stdout) && not (is_pipe stderr) ->
    Format.eprintf "FAST Creating process: %a@." Omake_env.pp_print_string_pipe pipe;
    let code, venv, value =
      create_apply_top venv stdin stdout stderr apply
    in
    Omake_env.ResultPid (code, venv, value)
  | _ ->
    Format.eprintf "SLOW Creating process: %a@." Omake_env.pp_print_string_pipe pipe;
    let pgrp = create_pipe_exn venv true stdin stdout stderr pipe in
    let job  = new_job pgrp (Some pipe) in
    if !Omake_shell_type.debug_shell then
      Format.eprintf "Started process with pgrg %i, internal id %i@." job.job_pgrp job.job_id;
    job.job_state <- JobBackground;
    InternalPid job.job_id
  )

(*
 * This is an explicit wait function.
 * It is exactly like the wait_top function,
 * except we print results.
 *)
let wait job =
   let id = job.job_id in
      try
         match fst (wait_top_aux job) with
            JobExited 0 ->
               Format.eprintf "*** osh: [%d] Done@." id
          | JobExited code ->
               Format.eprintf "*** osh: [%d] Exited with code %d@." id code
          | JobSignaled code ->
               Format.eprintf "*** osh: [%d] Signaled with code %d@." id code
          | JobStopped _ ->
               Format.eprintf "*** osh: [%d] Stopped@." id
      with
         Unix.Unix_error (Unix.EINTR, _, _)
       | Sys.Break ->
            Format.eprintf "*** osh: [%d] Wait interrupted@." id

(*
 * Clear out any processes that have completed.
 *)
let cleanup_top_aux () =
   if !Omake_shell_type.debug_shell then
      Format.eprintf "cleanup_top_aux@.";
   let pid, status = Omake_shell_sys.wait 0 true true in
   let job = find_job_by_pgrp pid in
   let pid = job.job_id in
   let code = finalize_job job status in
      if !Omake_shell_type.debug_shell then
         Format.eprintf "cleanup_top_aux: %a@." pp_print_status code;
      pid, code

let rec cleanup venv =
   let code =
      try Some (cleanup_top_aux ()) with
         Not_found
       | Unix.Unix_error _ ->
            None
   in
      match code with
         Some (pid, code) ->
            print_exit_code venv true pid code;
            cleanup venv
       | None ->
            ()

(*
 * Place it in the background.
 * It should be currently suspended.
 *)
let bg_job job =
   Omake_shell_sys.kill job.job_pgrp SigCont;
   job.job_state <- JobBackground

(*
 * Bring a job to the foreground.
 * Give it the terminal.
 *)
let fg_job venv job =
   Omake_shell_sys.set_tty_pgrp job.job_pgrp;
   Omake_shell_sys.kill job.job_pgrp SigCont;
   job.job_state <- JobForeground;
   wait_top venv job

(*
 * Stop a job.
 *)
let stop_job venv job =
   Omake_shell_sys.kill job.job_pgrp SigStop;
   wait_top venv job

(*
 * Kill a job.
 *)
let kill_job job signal =
   Omake_shell_sys.kill job.job_pgrp signal

(************************************************************************
 * Toplevel shell utilities.
 *)

(*
 * List the jobs.
 *)
let jobs _ =
   IntTable.iter (fun _ job -> Format.printf "%a@." pp_print_job job) shell.shell_jobs

(*
 * Get the identified job.
 *)
let job_of_pid pos pid =
   try IntTable.find shell.shell_jobs pid with
      Not_found ->
         raise (Omake_value_type.OmakeException (pos, StringIntError ("Omake_shell_job.job_of_pid: no such job", pid)))

(*
 * Process management.
 *)
let bg _ pos pid =
   let pos = Pos.string_pos "bg" pos in
      bg_job (job_of_pid pos pid)

let fg venv pos pid =
   let pos = Pos.string_pos "fg" pos in
      ignore (fg_job venv (job_of_pid pos pid))

let stop venv pos pid =
   let pos = Pos.string_pos "stop" pos in
      ignore (stop_job venv (job_of_pid pos pid))

let kill _ pos pid signal =
   let pos = Pos.string_pos "kill" pos in
      kill_job (job_of_pid pos pid) signal

let wait _ pos pid =
   let pos = Pos.string_pos "wait" pos in
      wait (job_of_pid pos pid)

let waitpid venv pos (pid : Omake_env.pid) :  int * Unix.process_status * Omake_value_type.t=
  let pos = Pos.string_pos "waitpid" pos in
  match pid with
  | ExternalPid pid ->
    if !Omake_shell_type.debug_shell then
      Format.eprintf "Omake_shell_job.waitpid: external id %i@." pid;
    let _, status = Unix.waitpid [] pid in
    pid, status, Omake_value_type.ValNone
  | InternalPid pid ->
    if !Omake_shell_type.debug_shell then
      Format.eprintf "Omake_shell_job.waitpid: internal id %i@." pid;
    let status = wait_pid venv (job_of_pid pos pid) in
    pid, status, ValNone
  | ResultPid (code, _, value) ->
    0, Unix.WEXITED code, value

