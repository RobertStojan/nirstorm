function install_package(package_name, source_dir, target_dir, mode, extras, dry)
% Install a package and manage version. From given package_name and a version 
% tag that must be defined in <source_dir>/VERSION, the function ensures 
% that only one package version is installed in the target directory.
% The set of files/folders to install are declared in the MANIFEST file that must
% be available in the source_dir (see below "MANIFEST file format").
% Installation can copy files (windows/linux) or make symbolic links (linux only) 
% depending on the value of mode: 'copy' or 'link'. respectively.
% A version tag must be specified in <source_dir>/VERSION (see below 
% "VERSION file format")
% A uninstall script named <source_dir>/<package_name>_<version_tag>_uninstall.m 
% is created. It is used to clean a previous installation.
% If items to be installed already exist in target_dir disregarding
% uninstall script, the user is warned and they are backuped by suffixing
% "_backuped_by_<package_name>_<version_tag>". The uninstallation script 
% will restore them.
%
% MANIFEST file format:
% one path per line. Each path is relative to given source_dir.
% Path can be a filename or a folder. If it's a folder then the whole 
% directory is copied or linked.
% Example:
%   my_func.m
%   script/my_script.m
%   data
%   
% VERSION file format:
% contains only one string on the first line. Only alphanumerical
% characters and "." are allowed.
% IMPORTANT: version tag is case insentive, eg the version tage "stable_v1.2" 
% is considered the same as "Stable_V1.2".

% Args:
%     - package_name (str):
%         package name. Must be a valid matlab identifier. See function isvarname
%     - source_dir (str):
%         path of source directory which must contain MANIFEST and VERSION
%         files.
%     - target_dir (str):
%         target installation folder.
%    [- mode (str):]
%         if 'copy': all files/folder are copied to target_dir
%         if 'link': symbolic links pointing to items in source_dir are
%                    created in target_dir.
%         Default is 'copy'.
%    [- extras (cell array of str):]
%         Tags to include extra the content of other MANIFEST files.
%         For each tag, a MANIFEST file named "MANIFEST.<tag>" must be
%         available in the source directory.
%    [- dry (boolean):]
%         If 1 then no file operations are displayed, not executed.
%         If 0 (default) then file operations are performed.
if nargin < 4
    mode = 'copy';
end
if nargin < 5
    extras = {};
end
if nargin < 6
    dry = 0;
end
check_inputs(package_name, source_dir, target_dir, mode, extras, dry);

uninstall_package(package_name, target_dir);
[install_operations, uninstall_operations] = resolve_file_operations(package_name, source_dir, target_dir, mode, extras);
execute_file_operations(install_operations, dry);
uninstall_script = fullfile(target_dir, ['uninstall_' package_name '.m']);
uninstall_header = sprintf('disp(''Uninstalling %s--%s from %s...'');', ...
                           package_name, get_version_tag(source_dir), target_dir);
make_file_operations_script(uninstall_operations, uninstall_script, uninstall_header, dry);
end

function make_file_operations_script(operations, script_fn, header, dry)

content = {header};
for iop=1:length(operations)
    operation = operations(iop);
    if ~isempty(operation.file1)
        if ~isfield(operation, 'dont_check_file1')
            content{end+1} = code_check_file_exists(operation.file1);
        else
            content{end+1} = sprintf('if exist(''%s'', ''file'')', operation.file1);
        end
        if ~isfield(operation, 'dont_check_file2') && ~isempty(operation.file2)
            content{end+1} = code_check_file_doesnt_exist(operation.file2);
        end
        switch operation.action
            case 'copy'
                content{end+1} = sprtinf('copyfile ''%s'' ''%s'';', operation.file1, operation.file2);
            case 'link'
                content{end+1} = code_check_not_windows();
                content{end+1} = sprintf('unix(''ln -s %s %s'')', operation.file1, operation.file2);
            case 'remove'              
                content{end+1} = strjoin({sprintf('if ~isempty(strfind(computer, ''WIN'')) || unix(''test -L %s'')', operation.file1), ...
                                          sprintf('    if isdir(''%s'')', operation.file1), ...
                                          sprintf('        rmdir(''%s'', ''s'');', operation.file1), ...
                                                  '    else', ...
                                          sprintf('        delete(''%s'');', operation.file1), ...
                                                  '    end', ...
                                                  'else',...
                                          sprintf('    delete(''%s'');', operation.file1), ...       
                                                  'end',...
                                                  'try', ...
                                          sprintf('    rmdir(''%s'');', fileparts(operation.file1)),...
                                                  'catch', ...
                                                  'end'}, '\n');
            case 'move'
                content{end+1} = sprintf('movefile(''%s'', ''%s'');\n', operation.file1, operation.file2);
            otherwise
                throw(MException('DistPackage:BadOperation','Bad operation: %s', operation.action));
        end
        if isfield(operation, 'dont_check_file1')
            content{end+1} = 'end';
        end
    end
end
content = sprintf('%s\n', strjoin(content, '\n'));
if ~dry
    fout = fopen(script_fn, 'w');
    fprintf(fout, content);
    fclose(fout);
else
    fprintf(content);
end
end

function code = code_check_file_exists(fn)
code = {sprintf('if ~exist(fullfile(pwd, ''%s''), ''file'')', fn), ...
        sprintf('    throw(MException(''DistPackage:FileNotFound'',''"%s" not found''));',fn),...
        'end'};
code = strjoin(code, '\n');
end

function code = code_check_file_doesnt_exist(fn)
code = {sprintf('if exist(fullfile(pwd,''%s''), ''file'')', fn), ...
        sprintf('    throw(MException(''DistPackage:FileExists'',''File "%s" exists''));',fn),...
        'end'};
code = strjoin(code, '\n');
end

function code = code_check_not_windows()
code = {'if ~isempty(strfind(computer, ''WIN''))', ...
        '    throw(MException(''DistPackage:BadOperation'', ''windows not supported''));', ...
        'end'};
code = strjoin(code, '\n');
end

function [install_operations, uninstall_operations] = resolve_file_operations(package_name, source_dir, target_dir, mode, extras)
manifest_fns = [{fullfile(source_dir, 'MANIFEST')} ...
                cellfun(@(extra_tag) fullfile(source_dir, ['MANIFEST.' extra_tag]), extras, 'UniformOutput', false)];
backup_prefix = ['_backuped_by_' package_name '_' get_version_tag(source_dir) '_'];
iop = 1;
uop = 1;
for im=1:length(manifest_fns)
    manifest_fn = manifest_fns{im};
    if ~exist(manifest_fn, 'file')
       throw(MException('DistPackage:FileNotFound', [manifest_fn ' does not exist in source dir']));
    end
    source_rfns = read_manifest(manifest_fn);
    for ifn=1:length(source_rfns)
        source_fn = fullfile(source_dir, source_rfns{ifn});
        if ~exist(source_fn, 'file')
            throw(MException('DistPackage:FileNotFound', [source_fn ' does not exist in source dir']));
        end
        target_fn = fullfile(target_dir, source_rfns{ifn});
        if exist(target_fn, 'file')
            backup_rfn = add_fn_prefix(source_rfns{ifn}, backup_prefix);
            warning(['"' source_rfns{ifn} '" already exists in target directory. ' ...
                     'It will be backuped to "' backup_rfn '"']);
            install_operations(iop).file1 = target_fn;
            install_operations(iop).action = 'move';
            install_operations(iop).file2 = fullfile(target_dir, backup_rfn);
            iop = iop + 1;
        end
        install_operations(iop).file1 = source_fn;
        install_operations(iop).action = mode;
        install_operations(iop).file2 = target_fn;
        iop = iop + 1;

        uninstall_operations(uop).file1 = source_rfns{ifn};
        uninstall_operations(uop).action = 'remove';
        uninstall_operations(uop).file2 = '';
        uop = uop + 1;
        
        if exist(target_fn, 'file')
            uninstall_operations(uop).file1 = backup_rfn;
            uninstall_operations(uop).action = 'move';
            uninstall_operations(uop).file2 = source_rfns{ifn};
            uninstall_operations(uop).dont_check_file1 = 1;
            uop = uop + 1;
        end
    end
end
end

function fns = read_manifest(manifest_fn)
fns = cellfun(@(fn) strtrim(fn), strsplit(fileread(manifest_fn), '\n'), 'UniformOutput', false);
fns = fns(~cellfun(@isempty, fns));
files_not_found = cellfun(@(fn) ~exist(fullfile(fileparts(manifest_fn), fn), 'file'), fns);
if any(files_not_found)
    throw(MException('DistPackage:FileNotFound', ...
                     sprintf('Non-existing files from %s:\n%s', ...
                             manifest_fn, strjoin(fns(files_not_found), '\n'))));
end
end

function new_fn = add_fn_prefix(fn, prefix)
[rr, bfn, ext] = fileparts(fn);
new_fn = fullfile(rr, [prefix bfn  ext]);
end

function execute_file_operations(operations, dry)
for iop=1:length(operations)
    operation = operations(iop);
    if isdir(operation.file2) && exist(operation.file2, 'dir') || exist(operation.file2, 'file')
        throw(MException('DistPackage:TargetExists', ... 
                         ['Target ' operation.file2 ' already exists']));
    end
    if ~isfield(operation, 'dont_check_file1') && (isdir(operation.file1) && ~exist(operation.file1, 'dir') || ~exist(operation.file1, 'file'))
        throw(MException('DistPackage:FileNotFound', [operation.file1 ' does not exist']));
    end
    if ~dry
        switch operation.action
            case 'copy'
                dest_folder = fileparts(operation.file2);
                if ~exist(dest_folder, 'dir')
                    mkdir(dest_folder);
                end
                copyfile(operation.file1, operation.file2);
            case 'link'
                dest_folder = fileparts(operation.file2);
                if ~exist(dest_folder, 'dir')
                    mkdir(dest_folder);
                end
                unix(['ln -s ' operation.file1 ' ' operation.file2]);
            case 'remove'
                if ~isempty(strfind(computer, 'WIN')) || unix(['test -L ' operation.file1])
                    if isdir(operation.file1)
                        rmdir(operation.file1, 's');
                    else
                        delete(operation.file1);
                    end
                else %symlink
                    delete(operation.file1);
                end
            case 'move'
                dest_folder = fileparts(operation.file2);
                if ~exist(dest_folder, 'dir')
                    mkdir(dest_folder);
                end
                movefile(operation.file1, operation.file2);
            otherwise
                throw(MException('DistPackage:BadOperation', ...
                                 ['Bad operation: ' operation.action]))
        end
    else
        switch operation.action
            case 'copy'
                disp(['copy ' operation.file1 ' to ' operation.file2]);
            case 'link'
                disp(['link ' operation.file1 ' to ' operation.file2]);
            case 'remove'
                disp(['remove ' operation.file1]);
            case 'move'
                disp(['move ' operation.file1 ' to ' operation.file2]);
        end
    end
end

end

function version_tag = get_version_tag(source_dir)

version_fn = fullfile(source_dir, 'VERSION');
if ~exist(version_fn, 'file')
   throw(MException('DistPackage:FileNotFound', 'VERSION file does not exist in source dir'));
end

content = fileread(version_fn);
if ~isempty(content) && strcmp(sprintf('\n'), content(end))
    content = content(1:(end-1));
end
version_tag = strtrim(content);
if isempty(regexp(version_tag, '^[a-zA-Z0-9_.]+$', 'once'))
    throw(MException('DistPackage:BadVersionTag', ...
                    ['Bad version tag in VERSION "' version_tag '".Must only contain '...
                     'alphanumerical characters, dot or underscore']));
end

end

function check_inputs(package_name, source_dir, target_dir, mode, extras, dry)
if~isvarname(package_name)
    throw(MException('DistPackage:BadPackageName', ...
                     'Package name must be a valid matlab identifier'));
end
if ~exist(source_dir, 'dir')
   throw(MException('DistPackage:DirNotFound', 'source_dir does not exist'));
end

if ~exist(target_dir, 'dir')
   mkdir(target_dir);
end 

if ~(strcmp(mode, 'copy') || strcmp(mode, 'link'))
    throw(MException('DistPackage:BadOption', 'mode can either be "copy" or "link"'));
end

if ~isempty(strfind(computer, 'WIN')) && strcmp(mode, 'link')
    throw(MException('DistPackage:BadOption', 'link mode only available for linux'));
end

if ~iscell(extras) || any(cellfun(@(e) ~ischar(e), extras))
    throw(MException('DistPackage:BadOption', 'extra must be a cell array of str'));
end

if ~(dry==0 || dry==1)
   throw(MException('DistPackage:BadOption', 'dry must be either 1 or 0'));
end

end