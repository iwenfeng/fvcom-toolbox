function write_FVCOM_forcing(Mobj, fileprefix, data, infos, fver)
% Write data out to FVCOM NetCDF forcing file.
% 
% write_FVCOM_forcing(fvcom_forcing_file, data, infos, fver)
% 
% DESCRIPTION:
%   Takes the given interpolated data (e.g. from grid2fvcom) and writes out
%   to a NetCDF file.
% 
% INPUT:
%   Mobj - MATLAB mesh object
%   fileprefix - Output NetCDF file prefix (plus path) will be
%       fileprefix_{wnd,hfx,evap}.nc if fver is '3.1.0', otherwise output
%       files will be fileprefix_wnd.nc.
%   data - Struct of the data to be written out.
%   infos - Additional remarks to be written to the "infos" NetCDF variable
%   fver - Output for version 3.1.0 or 3.1.6. The latter means all the
%       forcing can go in a single file, the former needs separate files
%       for specific forcing data (wind, heating and precipitation).
% 
% The fields in data may be called any of:
%     - 'u10', 'v10', 'uwnd', 'vwnd'
%     - 'P_E'
%     - 'prate'
%     - 'nswrs'
%     - 'shtfl'
%     - 'time'
%     - 'lon'
%     - 'lat'
%     - 'x'
%     - 'y'
% 
% OUTPUT:
%   FVCOM wind speed forcing NetCDF file(s)
% 
% 
% Author(s):
%   Pierre Cazenave (Plymouth Marine Laboratory)
% 
% Revision history:
%   2012-11-01 - First version based on the parts of grid2fvcom_U10V10.m
%   which dealt with writing the NetCDF file. This version now dynamically
%   deals with varying numbers of forcing data.
% 
%==========================================================================

multi_out = false; % default to 3.1.6, single output file
if nargin < 4 || nargin > 5
    error('Incorrect number of arguments')
elseif nargin == 5
    if strcmpi(fver, '3.1.0')
        multi_out = true;
    end
end

subname = 'write_FVCOM_forcing';

global ftbverbose;
if(ftbverbose)
  fprintf('\n')
  fprintf(['begin : ' subname '\n'])
end

tri = Mobj.tri;
nVerts = Mobj.nVerts;
nElems = Mobj.nElems;
ntimes = numel(data.time);

if strcmpi(Mobj.nativeCoords,'cartesian')
    x = Mobj.x;
    y = Mobj.y;
else
    x = Mobj.lon;
    y = Mobj.lat;
end

%--------------------------------------------------------------------------
% Create the NetCDF header for the FVCOM forcing file
%--------------------------------------------------------------------------

if multi_out
    suffixes = {'_wnd', '_hfx', '_evap'};
else
    suffixes = {'_wnd'};
end

for i=1:length(suffixes)
    
    nc = netcdf.create([fileprefix, suffixes{i}, '.nc'], 'clobber');

    netcdf.putAtt(nc,netcdf.getConstant('NC_GLOBAL'),'type','FVCOM Forcing File')
    netcdf.putAtt(nc,netcdf.getConstant('NC_GLOBAL'),'source','FVCOM grid (unstructured) surface forcing')
    netcdf.putAtt(nc,netcdf.getConstant('NC_GLOBAL'),'references','http://fvcom.smast.umassd.edu, http://codfish.smast.umassd.edu, http://www.pml.ac.uk')
    netcdf.putAtt(nc,netcdf.getConstant('NC_GLOBAL'),'institution','Plymouth Marine Laboratory')
    netcdf.putAtt(nc,netcdf.getConstant('NC_GLOBAL'),'history','Created with write_FVCOM_forcing.m from the fvcom-toolbox (https://github.com/pwcazenave/fvcom-toolbox)')
    netcdf.putAtt(nc,netcdf.getConstant('NC_GLOBAL'),'infos',infos)

    % Dimensions
    three_dimid=netcdf.defDim(nc,'three',3);
    nele_dimid=netcdf.defDim(nc,'nele',nElems);
    node_dimid=netcdf.defDim(nc,'node',nVerts);
    time_dimid=netcdf.defDim(nc,'time',netcdf.getConstant('NC_UNLIMITED'));

    % Time variables
    time_varid=netcdf.defVar(nc,'time','NC_FLOAT',time_dimid);
    netcdf.putAtt(nc,time_varid,'long_name','time');
    netcdf.putAtt(nc,time_varid,'units','days since 1858-11-17 00:00:00');
    netcdf.putAtt(nc,time_varid,'format','modified julian day (MJD)');
    netcdf.putAtt(nc,time_varid,'time_zone','UTC');

    itime_varid=netcdf.defVar(nc,'Itime','NC_INT',time_dimid);
    netcdf.putAtt(nc,itime_varid,'units','days since 1858-11-17 00:00:00');
    netcdf.putAtt(nc,itime_varid,'format','modified julian day (MJD)');
    netcdf.putAtt(nc,itime_varid,'time_zone','UTC');

    itime2_varid=netcdf.defVar(nc,'Itime2','NC_INT',time_dimid);
    netcdf.putAtt(nc,itime2_varid,'units','msec since 00:00:00');
    netcdf.putAtt(nc,itime2_varid,'time_zone','UTC');

    % Space variables
    x_varid=netcdf.defVar(nc,'x','NC_FLOAT',node_dimid);
    netcdf.putAtt(nc,x_varid,'long_name','nodal x-coordinate');
    netcdf.putAtt(nc,x_varid,'units','m');

    y_varid=netcdf.defVar(nc,'y','NC_FLOAT',node_dimid);
    netcdf.putAtt(nc,y_varid,'long_name','nodal y-coordinate');
    netcdf.putAtt(nc,y_varid,'units','m');

    nv_varid=netcdf.defVar(nc,'nv','NC_FLOAT',[nele_dimid, three_dimid]);
    netcdf.putAtt(nc,nv_varid,'long_name','nodes surrounding element');

    % Since we have a dynamic number of variables in the struct, try to be a
    % bit clever about how to create the output variables. 
    fnames = fieldnames(data);
    used_varids = cell(0);
    used_fnames = cell(0);
    used_dims = cell(0); % exclude time (assume all variables vary in time)

    for vv=1:length(fnames)
        % Need to check both whether we have the data but also whether
        % we're outputting to several NetCDF files. If so, we drop some
        % variables if we're in the wrong file loop.
        switch fnames{vv}
            case {'uwnd', 'u10'}
                if strcmpi(suffixes{i}, '_wnd') || ~multi_out
                    % wind components (assume we have v if we have u)
                    u10_varid=netcdf.defVar(nc,'U10','NC_FLOAT',[nele_dimid, time_dimid]);
                    netcdf.putAtt(nc,u10_varid,'long_name','Eastward 10-m Velocity');
                    netcdf.putAtt(nc,u10_varid,'standard_name','Eastward Wind Speed');
                    netcdf.putAtt(nc,u10_varid,'units','m/s');
                    netcdf.putAtt(nc,u10_varid,'grid','fvcom_grid');
                    netcdf.putAtt(nc,u10_varid,'type','data');

                    v10_varid=netcdf.defVar(nc,'V10','NC_FLOAT',[nele_dimid, time_dimid]);
                    netcdf.putAtt(nc,v10_varid,'long_name','Northward 10-m Velocity');
                    netcdf.putAtt(nc,v10_varid,'standard_name','Northward Wind Speed');
                    netcdf.putAtt(nc,v10_varid,'units','m/s');
                    netcdf.putAtt(nc,v10_varid,'grid','fvcom_grid');
                    netcdf.putAtt(nc,v10_varid,'type','data');

                    u10_node_varid=netcdf.defVar(nc,'U10_node','NC_FLOAT',[node_dimid, time_dimid]);
                    netcdf.putAtt(nc,u10_node_varid,'long_name','Eastward 10-m Velocity');
                    netcdf.putAtt(nc,u10_node_varid,'standard_name','Eastward Wind Speed');
                    netcdf.putAtt(nc,u10_node_varid,'units','m/s');
                    netcdf.putAtt(nc,u10_node_varid,'grid','fvcom_grid');
                    netcdf.putAtt(nc,u10_node_varid,'type','data');

                    v10_node_varid=netcdf.defVar(nc,'V10_node','NC_FLOAT',[node_dimid, time_dimid]);
                    netcdf.putAtt(nc,v10_node_varid,'long_name','Northward 10-m Velocity');
                    netcdf.putAtt(nc,v10_node_varid,'standard_name','Northward Wind Speed');
                    netcdf.putAtt(nc,v10_node_varid,'units','m/s');
                    netcdf.putAtt(nc,v10_node_varid,'grid','fvcom_grid');
                    netcdf.putAtt(nc,v10_node_varid,'type','data');

                    used_varids = [used_varids, {'u10_varid', 'v10_varid', 'u10_node_varid', 'v10_node_varid'}];
                    used_fnames = [used_fnames, {'uwnd', 'vwnd', 'uwnd', 'vwnd'}];
                    used_dims = [used_dims, {'nElems', 'nElems', 'nVerts', 'nVerts'}];
                end

            case 'P_E'
                if strcmpi(suffixes{i}, '_evap') || ~multi_out
                    % Evaporation
                    pe_varid=netcdf.defVar(nc,'evap','NC_FLOAT',[nele_dimid, time_dimid]);
                    netcdf.putAtt(nc,pe_varid,'long_name','Evaporation');
                    netcdf.putAtt(nc,pe_varid,'description','Evaporation, ocean losing water is negative');
                    netcdf.putAtt(nc,pe_varid,'units','m s-1');
                    netcdf.putAtt(nc,pe_varid,'grid','fvcom_grid');
                    netcdf.putAtt(nc,pe_varid,'coordinates','');
                    netcdf.putAtt(nc,pe_varid,'type','data');

                    used_varids = [used_varids, 'pe_varid'];
                    used_fnames = [used_fnames, fnames{vv}];
                    used_dims = [used_dims, 'nElems'];
                end
                
            case 'prate'
                if strcmpi(suffixes{i}, '_evap') || ~multi_out
                    % Precipitation
                    prate_varid=netcdf.defVar(nc,'precip','NC_FLOAT',[nele_dimid, time_dimid]);
                    netcdf.putAtt(nc,prate_varid,'long_name','Precipitation');
                    netcdf.putAtt(nc,prate_varid,'description','Precipitation, ocean losing water is negative');
                    netcdf.putAtt(nc,prate_varid,'units','m s-1');
                    netcdf.putAtt(nc,prate_varid,'grid','fvcom_grid');
                    netcdf.putAtt(nc,prate_varid,'coordinates','');
                    netcdf.putAtt(nc,prate_varid,'type','data');

                    used_varids = [used_varids, 'prate_varid'];
                    used_fnames = [used_fnames, fnames{vv}];
                    used_dims = [used_dims, 'nElems'];
                end

            case 'nswrs'
                if strcmpi(suffixes{i}, '_hfx') || ~multi_out
                    % Shortwave radiation
                    nswrs_varid=netcdf.defVar(nc,'short_wave','NC_FLOAT',[nele_dimid, time_dimid]);
                    netcdf.putAtt(nc,nswrs_varid,'long_name','Short Wave Radiation');
                    netcdf.putAtt(nc,nswrs_varid,'units','W m-2');
                    netcdf.putAtt(nc,nswrs_varid,'grid','fvcom_grid');
                    netcdf.putAtt(nc,nswrs_varid,'coordinates','');
                    netcdf.putAtt(nc,nswrs_varid,'type','data');

                    used_varids = [used_varids, 'nswrs_varid'];
                    used_fnames = [used_fnames, fnames{vv}];
                    used_dims = [used_dims, 'nElems'];
                end
                
            case 'shtfl'
                if strcmpi(suffixes{i}, '_hfx') || ~multi_out
                    % Surface net heat flux
                    nhf_varid=netcdf.defVar(nc,'net_heat_flux','NC_FLOAT',[nele_dimid, time_dimid]);
                    netcdf.putAtt(nc,nhf_varid,'long_name','Surface Net Heat Flux');
                    netcdf.putAtt(nc,nhf_varid,'units','W m-2');
                    netcdf.putAtt(nc,nhf_varid,'grid','fvcom_grid');
                    netcdf.putAtt(nc,nhf_varid,'coordinates','');
                    netcdf.putAtt(nc,nhf_varid,'type','data');

                    used_varids = [used_varids, 'nhf_varid'];
                    used_fnames = [used_fnames, fnames{vv}];
                    used_dims = [used_dims, 'nElems'];
                end
                
            case {'time', 'lon', 'lat', 'x', 'y'}
                continue

            otherwise
                if(ftbverbose)
                    warning('Unknown or unused input data type: %s', fnames{vv})
                end
        end
    end

    % End definitions
    netcdf.endDef(nc);

    % Put the easy ones in first.
    netcdf.putVar(nc,nv_varid, tri');
    netcdf.putVar(nc,time_varid,0,ntimes,data.time);
    netcdf.putVar(nc,itime_varid,0,ntimes,floor(data.time));
    netcdf.putVar(nc,itime2_varid,0,ntimes,mod(data.time,1)*24*3600*1000);
    netcdf.putVar(nc,x_varid,x);
    netcdf.putVar(nc,y_varid,y);

    % Now do the dynamic ones.
    for ff=1:length(used_varids)
        if strcmpi(used_dims(ff), 'nVerts')
            eval(['netcdf.putVar(nc,',char(used_varids(ff)),',[0,0],[',char(used_dims{ff}),',ntimes],data.(used_fnames{ff}).node)'])
        else
            eval(['netcdf.putVar(nc,',char(used_varids(ff)),',[0,0],[',char(used_dims{ff}),',ntimes],data.(used_fnames{ff}).data)'])
        end
    end

%     netcdf.putVar(nc,u10_varid,[0,0],[nElems,ntimes],fvcom_u10);
%     netcdf.putVar(nc,v10_varid,[0,0],[nElems,ntimes],fvcom_v10);
%     netcdf.putVar(nc,u10_node_varid,[0,0],[nVerts,ntimes],fvcom_u10_node);
%     netcdf.putVar(nc,v10_node_varid,[0,0],[nVerts,ntimes],fvcom_v10_node);

    % Close the NetCDF files
    netcdf.close(nc);
end